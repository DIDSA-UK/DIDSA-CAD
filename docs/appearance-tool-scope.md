# Appearance tool (the "Vision tool") — scope

**Status:** being built on branch `claude/appearance-and-scenes` (both repos), milestone by milestone; see Progress below. Written 18 Oct 2026 from the owner's request during the scenes scope (`docs/scenes-scope.md`):
grow the Colour tool into a **Vision tool** with transparency, reflectivity and luminescence, a full colour picker as well as the
palette, and a paint gun that can be set to colour a **mesh**, a **part** or its **parent assembly**. **Owner** marks the owner's words and
decisions; the rest are proposals the owner accepted. Revised the same day with the owner's answers (section 8). In the apps the tool is
called **Appearance** (Owner).

## Progress

| Phase | Summary | Status | Where |
|---|---|---|---|
| V1 | Backend: record, three storage places, D3 resolution + golden vectors, endpoints, `Occurrence.color` alias, glb materials + `instance_path`, delete cascade, validation, native round trip | Done (M1; not merged) | CAD `claude/appearance-and-scenes` |
| V2 | DIDSA-VR Appearance tool | Not started (M2) | VR `claude/appearance-and-scenes` |
| V3 | Flat app | Not started (M5) | CAD |
| V4 | STEP colours | Not started (M6) | CAD |

Update this table with every milestone.

## V1 implementation notes (what was built, and where it is more precise than the text)

- **Where:** the record and the rule are `backend/app/document/appearance.py` (pure Python: no OCCT, no pydantic, so it is the
  reference the clients copy); the endpoints, checks, cascade and the resolution model the glb paints from are
  `appearance_routes.py`; shared path helpers (`#pattern:` copies, "goes through this occurrence") are `occurrence_paths.py`
  (scenes reuse them); the materials are `mesh_export.material_for_appearance`.
- **Golden vectors:** `tools/appearance_vectors/generate.py` -> `docs/appearance/vectors.json` (57 cases; the backend's copy is
  `backend/tests/data/appearance_vectors.json`, `--check` keeps the two in step). Each case is a resolution model (the plain-dict
  shape in `appearance.py`'s docstring), an instance path, a body and face, an optional scene, and the expected fields. The GDScript
  (V2) and Dart (V3) copies are tested against the docs copy.
- **"Most specific wins" made exact** (D1 / D3; it gives the owner's order for every case in the list and settles the ones the list
  doesn't name): within one override list a face beats a body beats a whole node; then the node **nearest the face** wins; on the
  same node a named path beats Pattern (all N) beats Every <part> (N); the Whole assembly is under everything. So "Every Frame A
  blue" then "this Frame A red" gives one red (same node, named path wins), a pattern of *sub-assemblies* painted blue with one copy's
  sub-assembly row painted red gives that copy red, and a nearer sub-assembly beats a farther one. A tie (a source occurrence in two
  painted patterns) goes to the later override.
- **Whole assembly and the levels** (follows D3 as settled, flagged for the owner): the Whole assembly is under every other row *of
  its own assembly*, but it is still the top assembly's level, so it beats the colours stored in sub-assembly files and the parts' own
  `appearance` / `body_appearances` / `face_appearances` (the vectors `whole_beats_part_files`, `levels_whole_beats_sub_file`). A base
  coat that should sit *under* the parts' own colours would need a different rule; nothing else depends on this choice.
- **A Part's own `appearance` paints only its own bodies**, never what it places (painting a whole sub-assembly in its own file is
  its Whole assembly override, `path: ""`). An override with `path: ""` and a `body_id` paints one of the assembly's own bodies.
- **`Occurrence.color`** (D2): read as an override on that occurrence in the Part that places it; an explicit override with the same
  target keeps its own fields and takes the legacy colour only when it sets none. A PUT on a top-level occurrence's own override
  mirrors its colour into `color` (clearing the override clears `color`); a PATCH of `color` by an older client updates that override's
  colour (an empty string removes just the colour). As the scope says, the alias now paints what is inside a sub-assembly (it used to
  be per instance only).
- **Faces:** stored with the signature measured when they are set (wire `SubShapeRefSchema` has none), re-found with
  `subshape_identity.decide_subshape` before painting; one that can't be re-found paints nothing and is reported
  (`unresolved`, `face_current_index` in GET; `current_index` / `unresolved` in `PartResponse.face_appearances`).
- **glb (D7):** each instance's material is its resolved appearance (unset fields from `appearance.DEFAULT_LOOK`, the flat app's
  default material; `extras.appearance` lists only the fields that were set, so a client can use its own default for the rest).
  Opacity < 1 is `alphaMode: BLEND`; glow is `emissiveFactor` (the emission colour, or the base colour when only a strength is set)
  with `KHR_materials_emissive_strength` past 1; strength 0 is off. An instance whose faces resolve differently gets **one primitive
  per appearance**, each a uint32 index list into the same shared position / normal accessors, with that primitive's own
  `face_ids` / `body_ids` (in its index order) and the topology on the first primitive only. An assembly with no appearance anywhere
  is unchanged apart from the new node extra `instance_path` (the full occurrence path, `#pattern:` segments included; it moved here
  from the scenes scope's S1 because the VR gun needs it to paint one pattern copy).
- **Endpoints:** `PUT /parts/{id}/appearance-overrides` (set / replace / `appearance: null` clears one target; returns the list),
  `GET` (the list, legacy colours included with `legacy: true`, each with `unresolved`), `PATCH /parts/{id}` (`appearance`,
  `body_appearances`, `face_appearances`; omitted = unchanged, `appearance: null` clears, the map / list replace whole), and the
  three fields in `PartResponse`.
- **Delete cascade:** deleting an occurrence drops every override in the session whose path goes through it (any Part's list, not
  only the owner's); deleting a component pattern (or the occurrence that is its source) drops its copies' overrides and its
  Pattern (all N) override. Every placement (`same_part`) names a Part and stays; when nothing places it any more it is reported
  `part_not_placed`. A copy that a smaller count no longer derives is kept and reported (`pattern_copy_not_found`).
- **Native format:** the four Part fields are written only when set, so a file without them exports byte for byte as before; an
  invalid appearance or scope in a file is a 422 on import. No `SCHEMA_VERSION` bump.
- **Tests:** `backend/tests/test_appearance.py`.

## 1. Today

| What | Where | Limit |
|---|---|---|
| One colour per placed part | `Occurrence.color` (`"#RRGGBB"` or null), PATCH `/parts/{id}/occurrences/{occ}` | Colour only; per instance, **not inherited** down the tree; nothing below a placed part. |
| Flat app | `occurrence_colour_sheet.dart` (the colour disc) | Palette + hex. |
| DIDSA-VR | `colour_tool.gd` (tablet swatches + hex on the keyboard; the wheel's Paint gun); `set_group_color` paints a sub-assembly by writing **every member occurrence** | The assembly's own bodies (root content) can't be painted at all: they have no Occurrence. |
| Materials | `MaterialAssignment` (`Part.default_material`, `body_material_assignments`): name + density, for mass and STEP | Physical, not visual. Stays separate (D6). |
| Rendering | Flat: `flutter_scene` `PhysicallyBasedMaterial` (metallic / roughness already set in `mesh_data.dart`). VR: Godot `StandardMaterial3D` | Both already render the four properties below. |
| STEP export | `step_export.py` uses XCAF for names, material, mass | No colours written (D7). |

## 2. What an appearance is

One record, used everywhere: on a face, on a body, on a placed part, on a sub-assembly, and inside a scene's overrides (`docs/scenes-scope.md` D2).
It is the glTF / physically-based material model both renderers already use, so nothing is invented and it exports cleanly.

| Field | Range | Owner's word | Renders as |
|---|---|---|---|
| `colour` | `#RRGGBB` | colour | base colour (glTF `baseColorFactor`) |
| `opacity` | 0-1 (1 = solid) | transparency | alpha blend (glTF `alphaMode: BLEND`) |
| `metallic` | 0-1 | reflectivity | metal vs plastic (glTF `metallicFactor`) |
| `roughness` | 0-1 | reflectivity | matte vs glossy (glTF `roughnessFactor`) |
| `emission` | `#RRGGBB` + `emission_strength` 0-10 | luminescence | glow (glTF `emissiveFactor` + `KHR_materials_emissive_strength`) |

Every field is optional: an appearance that sets only `opacity` leaves the colour to whatever is beneath it (D3). **Recommendation:** show
"reflectivity" as two simple sliders, **Shine** (1 - roughness) and **Metal** (metallic), plus presets (Matte plastic, Gloss plastic,
Brushed metal, Polished metal, Glass, Glowing), because one slider can't tell polished plastic from metal.

## 3. Decisions

### D1. The gun's targets — **Owner: mesh (= body), part, parent assembly; faces folded in**

- **Face:** the one face you hit. **Owner:** "faces can come later unless it's an easy fold in"; it is (section 4, "Faces"), so v1 has it.
- **Mesh:** one **body** (one solid) of the part you hit. **Owner:** mesh means body.
- **Part:** the placed part you hit (one occurrence), as today.
- **Parent assembly:** the sub-assembly the part sits in, one level up per click, using the same levels as the VR grip latch and
  breadcrumb (`group_index.gd`), so "parent" can go as high as the top-level sub-assembly.

#### Choosing the target: click, or hold for the breadcrumb (**Owner**)

- **Click** (trigger down and up within 0.45 s): paints the **body** under the laser. The paint is applied on release, not on press,
  because a press might turn into a hold (today's Paint fires on press).
- **Click always paints the body** (Owner); no setting, no remembered level.
- **Hold** (0.45 s, the same time as the selection breadcrumb, `controller.gd` `CRUMB_HOLD_MS`): the breadcrumb panel opens at the hit
  point, reusing `group_breadcrumb.gd`. Its rows, innermost first:
  1. **Face**
  2. **Body** (lit when it opens: what a click would have done)
  3. **Part**
  4. **Pattern (all 4)**: every copy of the pattern this part belongs to (Owner). Shown only when the part is a pattern copy or a
     pattern's source.
  5. **Every Frame A (2)**: every placement of the same part in this assembly (Owner). Shown only when the part is placed more than once.
  6. each sub-assembly the part sits in, up to the top-level one
  7. **Whole assembly** (Owner: allowed, as the top row): a base coat under everything
- **Hover a row:** the model shows the outcome of a release, live. The target takes the new appearance and everything else keeps its
  own, so inheritance is visible (a bolt with its own colour stays that colour when its sub-assembly is previewed blue, D3). Brackets show
  the extent of the target; a haptic tick on each row change; the wrist names it ("Paint · Frame (sub-assembly), 4 parts").
- **Release on a row:** applies it, as one undo step. **Release off the panel:** nothing is painted (unlike the selection breadcrumb,
  which keeps the part there; for paint, a hold means "I want to choose", so letting go elsewhere is a cancel).
- **Before any press:** the laser outlines the body a click would paint (the outline only, no colour, so sweeping across a model doesn't
  flicker).
- **Each row shows what is there now:** a small swatch of the resolved appearance at that level, marked when that level has its own
  override ("set here"), so you can see where a colour comes from before changing it.
- **Clear** is a swatch like any other: painting "Clear" on a level removes that level's override, and the preview shows what shows
  through from below.
- **Context in the panel's title:** "Painting" normally, "Painting · temporary (mates relaxed)" in the sandbox, "Painting scene
  'Exploded'" while a scene is shown (D5).
- **Flat app:** the same rows in a context popup: click paints the body, a long press (touch) or right-click opens the list, hovering a
  row previews it.

How the wider rows are stored (D2's override list), so they keep meaning what was chosen as the assembly changes:

- **Pattern (all N):** one override on the pattern's source path with `scope: "pattern"`; every copy, including ones added later when
  the count grows, takes it.
- **Every <part>:** one override `{part_id, scope: "same_part"}`: every placement of that Part anywhere inside this assembly, at any
  depth, including ones added later. Still an override in the assembly; the part's own file is not touched (D2).
- **Whole assembly:** an override with an empty path, under everything else in this assembly.

Within one level (D3) the more specific target wins: face > body > part > pattern > every placement of the part > sub-assembly > whole
assembly. So "every Frame A blue" then "this Frame A red" gives one red and the rest blue.


### D2. Where an appearance is stored — **Recommendation**

Painting **in an assembly** never edits the files of the parts inside it: it is an *override in the assembly*, the way desktop CAD does
component appearances. Painting a part **on its own** (the design table, the flat app's part lens) edits the part itself.

- **In the assembly:** a new `Part.appearance_overrides` list on the assembly Part:
  `{path, body_id?, face?, appearance}`. `path` is an occurrence path from that assembly (the mate / scene convention, `#pattern:` segments
  allowed, so a single pattern copy can be painted); `body_id` narrows it to one body; `face` (a face `SubShapeRef` with its signature and
  lineage, the form fillets and mates already store) narrows it to one face; a path to a sub-assembly paints the whole group.
- **On the part itself:** `Part.appearance` (the whole part), `Part.body_appearances: {body_id: appearance}` and
  `Part.face_appearances: [{face, appearance}]`. These travel with the part
  into every assembly that uses it. This is also how an assembly's **own** bodies get painted (they are the assembly Part's own bodies), which
  removes today's "root content can't be painted" limit.
- `Occurrence.color` becomes a legacy alias: read as an override `{path: <occ>, appearance: {colour}}`; new writes go to
  `appearance_overrides`, and the base colour is mirrored into `color` so older clients still show it.

### D3. Which appearance wins — **Owner: higher levels beat lower levels**

For each face on screen, the fields are resolved one at a time (an override that sets only opacity keeps the colour from below):

1. the scene being shown (`docs/scenes-scope.md`), if any;
2. overrides in the assembly being viewed (the top one);
3. overrides stored in sub-assembly files, from the highest level down (a sub-assembly's file beats the files of the sub-assemblies
   inside it);
4. the part's own `face_appearances`, then `body_appearances`, then its own `appearance`;
5. the app's default look.

**Owner:** a higher level beats a lower one: what the assembly you are looking at says beats what any file below it says, which is the
usual CAD rule. *Within one level* (one assembly's own override list, or one part's own record) the most specific target wins, face >
body > part > sub-assembly, so painting a sub-assembly blue and then one bolt red does what you expect. (Read this way from the owner's
answer to the question that was asked, top assembly vs sub-assembly files; to be confirmed.)

### D4. Colour picker — **Owner: a full picker as well as the palette**

- **VR:** the palette stays (quick); a **picker** is added: a hue ring with a saturation-value square, driven by the laser like the
  tablet's sliders; a hex field (the popup keyboard); **recent colours**; and an **eyedropper** (shoot a part to take its appearance, all
  fields). Opacity, Shine, Metal and Glow as sliders, with a live preview swatch rendered with the real material (a small sphere, so
  shine and metal are visible).
- **Flat app:** the colour disc grows the same controls.
- Both apps keep a short list of **saved appearances** (presets plus your own) in their settings.

### D5. When painting is real, and when it isn't

- Normally a shot is a real edit: saved, undoable, marks the document unsaved.
- **Mates relaxed (the sandbox):** painting is temporary and goes back with the parts (DIDSA-VR today saves a colour straight away; the
  scenes scope already asks for this change).
- **A scene shown:** painting changes the scene (its overrides), not the model.

### D6. Materials stay physical

`MaterialAssignment` (density, for mass and STEP) and appearance stay separate: steel can be painted red. **Later (optional):** a material
library entry can carry a default appearance, used when nothing else sets one (step 4.5 of D3).

### D7. Export

- **STEP:** write colours (and, where STEP allows, transparency) through OCCT's `XCAFDoc_ColorTool`, per body and per placed instance,
  from the resolved appearance (D3, without any scene). Metal / shine / glow have no STEP equivalent and are not written.
- **glTF** (the assembly glb): the resolved appearance as each instance's material, so both clients and any external glTF viewer see the
  same thing. This replaces today's "the client paints the colour on top" (VR's `_apply_local_color`).

### D8. Later

Textures and decals; an "appearance from material" link (D6); the scene animation idea (`docs/roadmap.md`).

## 4. Rendering notes

- **Faces (why they fold in easily):** the pieces exist already. Picking: DIDSA-VR's `MeshIdentity.subshape_ref_for_hit` turns a laser
  hit into a face `SubShapeRef` (mates use it). Identity through edits: a face reference carries a signature and lineage
  (`docs/reference-identity-design.md`; fillet `edge_refs` and sketch references use it), and DIDSA-VR's `mate_health.gd` already reports
  a face that drifted; a face appearance that can't be re-found is reported the same way and kept until fixed or cleared. Rendering: the
  glb already splits a Part's mesh by colour and carries `face_ids` per triangle, and body-level appearance needs a split by body anyway;
  faces make the split key finer (body, face group), with no new mechanism. Cost to watch: a part with many differently painted faces
  becomes many primitives (draw calls), so faces sharing one appearance stay one primitive.
- **Transparency:** alpha-blended parts must be drawn after opaque ones and can sort wrongly against each other. Godot's Mobile renderer
  sorts per object; for see-through context parts that is acceptable. Use a depth pre-pass ("alpha with depth") so a see-through part
  doesn't show its own back faces. The VR ghost material is a working precedent.
- **Reflectivity** looks like something only with something to reflect: DIDSA-VR has a WorldEnvironment (its scene sky); the flat app's
  `flutter_scene` environment lighting needs checking on the device (its own `PhysicallyBasedMaterial` is already flagged for that).
- **Glow:** emission alone makes a surface bright and unlit; a halo needs the glow post-process, which costs frame time on Quest. Measure it
  before turning it on by default.

## 5. Data model sketch

```jsonc
// the assembly Part
"appearance_overrides": [
  {"path": "f676588a…/689e531a…", "appearance": {"colour": "#2F6FD6"}},                          // a sub-assembly: the whole frame
  {"path": "f676588a…/689e531a…/7214dfb8…", "body_id": "e8d7bb68…", "appearance": {"metallic": 1.0, "roughness": 0.2}}, // one bar's body
  {"path": "504857a3…#pattern:af676f33…:2", "appearance": {"opacity": 0.3}},                   // one pattern copy
  {"path": "504857a3…", "scope": "pattern", "pattern_id": "af676f33…", "appearance": {"colour": "#333333"}},             // every copy of the pattern
  {"part_id": "1d3363e0…", "scope": "same_part", "appearance": {"metallic": 1.0, "roughness": 0.3}},                      // every Leg placed
  {"path": "", "appearance": {"colour": "#D0D0D0"}},                                                                     // whole assembly
  {"path": "9f3c7747…", "body_id": "b2949a80…", "face": {"body_id": "b2949a80…", "shape_type": "face", "index": 4, "signature": {…}, "lineage": {…}},
   "appearance": {"colour": "#FFFFFF", "emission": "#FFFFFF", "emission_strength": 2.0}}          // one face: a glowing panel
],
// any Part, about itself
"appearance": {"colour": "#C8C8C8", "roughness": 0.6},
"body_appearances": {"b2949a80…": {"colour": "#8B5A2B", "roughness": 0.8}},
"face_appearances": [{"face": {…}, "appearance": {"colour": "#202020"}}]
```

Validation: path as in scenes (resolves from this Part, `#pattern:` allowed), `body_id` exists on the resolved Part, ranges as section 2,
no duplicate `(path or part_id, scope, body_id, face)`; a face ref must be a face of that body; `scope` is absent (this one),
`"pattern"` (with a `pattern_id` whose source is `path`) or `"same_part"` (with `part_id` and no `path`). Written only when non-empty, so existing files stay byte-identical; no `SCHEMA_VERSION` bump (the
`component_patterns` precedent). Delete cascade as for mates and scenes.

## 6. API sketch

| Method | Path | Notes |
|---|---|---|
| PUT | `/parts/{id}/appearance-overrides` | Set one `{path, body_id?, face?, appearance}` (replace that key's record); `appearance: null` clears it. |
| GET | `/parts/{id}/appearance-overrides` | List, with unresolved paths reported (as scenes do). |
| PATCH | `/parts/{id}` | `appearance`, `body_appearances`, `face_appearances` (the part's own). |
| GET | `/parts/{id}/assembly-mesh.glb` | Materials now carry the resolved appearance (D7). |

A shared reference implementation of the D3 resolution (Python, golden vectors for the Dart and GDScript copies) keeps the three apps
the same, alongside the scene composition vectors.

## 7. Phases

| Phase | What | Repo |
|---|---|---|
| V1 | Backend: appearance record, the three storage places, D3 resolution + vectors, endpoints, `Occurrence.color` alias, glb materials, delete cascade; tests. | CAD |
| V2 | DIDSA-VR: the Appearance tool (replacing Paint / Colours): gun targets face / body / part / parent assembly with the laser preview; picker, sliders, eyedropper, recent and saved appearances; temporary in the sandbox; materials from the glb. | VR |
| V3 | Flat app: the same controls in the colour disc; targets; materials from the glb. | CAD |
| V4 | STEP colours (D7). | CAD |
| — | Scenes (`docs/scenes-scope.md`) store appearance overrides with this record; S1 depends on V1's record (not on the rest). | both |

## 8. Settled (second revision)

1. "Mesh" means a **body** (Owner); **faces** are folded into v1 as the finest target (Owner: "unless it's an easy fold in"; section 4).
2. The tool is called **Appearance** (Owner). "Vision tool" stays only as this doc's working title.
3. **Higher levels beat lower levels** (Owner, D3), and within one level the most specific target wins (Owner confirmed).
4. **Choosing the target** is click (body) or hold for the breadcrumb with a live preview per row (Owner, D1).

5. **The breadcrumb** (Owner): a **Pattern (all N)** row, an **Every <part> (N)** row, **Whole assembly** as the top row, and
   **click always paints the body** (D1).
