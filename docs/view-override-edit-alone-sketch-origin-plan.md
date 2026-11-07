# View override, Edit Alone and sketch origin: plan

Source: the owner's request of 2026-11-07 (Flutter client). This plan is for the implementation session.
Code pointers were checked against `main` at `8228024`. Line numbers drift, so search for the named symbol if a line is off.
Nothing here has been built yet. The **Decisions** at the end each have a recommended answer. The owner answered 2a and 2c
and the origin button's placement on 2026-11-07 (marked **Owner** there). For the rest, check with the owner first, or build
the recommended answer and say that is what you did.

| Item | Summary | Kind | Size |
|---|---|---|---|
| 1 | View menu Body Colour / Body Transparency become a display override that beats every other appearance and covers the whole viewport (sub-parts and sub-assemblies too), with a button to turn it off | Bug + rework | Small-medium (client only) |
| 2 | **Edit Alone**: edit one component or sub-assembly on its own, inside the same screen, with a one-tap way back to the assembly | Feature | Medium (client only) |
| 3 | Sketch origin: choose the sketch's origin when defining a sketch (Body vertex, Sketch Point, line / curve endpoint, circle centre); sensible defaults (a face corner on a face, the plane origin on a plane) | Feature | Medium-large (backend + client) |
| 3d | DIDSA-VR: place a Sketch with a moved origin correctly; its own new face sketches get the same corner default | Follow-up in `DIDSA-UK/DIDSA-VR` | Small |

Items 1 and 2 are Flutter-only and do not touch DIDSA-VR. Item 3 changes the backend and the `.didsa` file, and DIDSA-VR builds
a Sketch's frame itself, so it needs 3d (see "DIDSA-VR" at the end of Item 3).

Suggested order: **1 → 2 → 3 (3a → 3d → 3b)**. 3d goes straight after the backend phase so DIDSA-VR is never left drawing
moved-origin sketches in the wrong place. They do not depend on each other. 1 is the smallest and fixes a real bug. 2 is client only and
reuses the focus stack. 3 needs a backend model change, a native-format change and reference-identity work, so it goes last.

## Progress

Branch `ccr-b90afddb-8kqv89`. Nothing here has been looked at on a device or the headset. Flutter 3.47.9 (CI's pin) ran the
client tests here; the widget tests that need a GPU skip (`PartViewport` reports "no real GPU backend in this sandbox"), so
**what a body looks like on screen is untested** for Items 1 and 2.

Decisions: the owner's answers (2a Edit Alone, 2c keep Isolate, the Pick origin button in both orientation modes) are built
as given. **Every other open decision was built as the recommended answer, without asking**: 1a (the on/off state is not
remembered; colour and opacity are), 1b (a switch named "Override appearance" plus the viewport chip), 1c (the sketch screen
is not covered), 2b (the edited component stays where it sits), 3a (bottom-left in the oriented frame, follows flip / rotate
until a manual pick), 3b (the geometry moves with the origin), 3c (not built).

| Item | What landed | Tests (added) | Ran here | Not run here |
|---|---|---|---|---|
| 1 | `ViewAppearanceOverride` (`viewport3d/view_appearance_override.dart`) with the pure `resolveInstanceLook` / `resolvePrimaryLook`; `PartViewport.appearanceOverride` (null = off) beats looks, `focusOccurrenceColorHex`, the colour disc and a scene on the primary bodies and on every placed instance (sub-parts and sub-assemblies; a shown scene goes through the same path), keeps the focus fade and the Select Other dim, and rebuilds both node sets when it changes. New keys `view_override_colour` / `view_override_opacity` are seeded from the old body keys, which are never rewritten (the mesh viewer and sketch screen keep them). The off look is now one grey: `buildAssemblyInstanceNode` defaults to `defaultBodyColourHex` and takes the scene roughness / metallic. View menu: a header, an "Override appearance" switch, Body Colour and Body Transparency with "Overriding: ..." / "Off: ..." subtitles; picking either turns it on, only the switch / chip / ribbon turns it off. The View ribbon tab (and so the phone Start menu's View tab) has Override, Body colour and Transparency. A chip at the top centre ("Appearance override · Turn off", hidden while presenting); the Appearance panel shows a banner with Turn off while it is on, and never turns it off itself. Off at every start (Decision 1a). **Differences from the plan text:** the viewport keeps its `bodyColourHex` / `bodyOpacity` (the sketch screen still uses them), `PartScreen` no longer passes them, so the root's own bodies now show the default grey when the override is off | `view_appearance_override_test.dart` (every combination of override x painted x tinted x focused x Select Other dim for instances and for primary bodies; value equality; the new keys: seeded, explicit wins, old keys untouched), `part_toolbar_test.dart` (the switch, subtitles, colour pick reports), `part_screen_test.dart` (starts off; Body Colour turns it on and the viewport gets a non-null override; the chip turns it off; the View tab's Override command), `appearance_panel_test.dart` (the banner and Turn off) | `flutter analyze` (no issues); the four files above; the whole of `part_screen_test.dart` (205 pass); `mesh_geometry_test.dart`, `part_viewport_test.dart`, `scene_display_test.dart` | That the rendered colour and see-through are right on screen (the widget tests skip the GPU), including a shown scene and that `buildAssemblyInstanceNode`'s default colour is the grey (GPU-bound; the colour choice is covered by the pure resolver instead). Not tried on a device |

---

## 1. View menu: Body Colour and Body Transparency as an override

### What happens now

- The phone/desktop hamburger menu's View section is `PartToolbar._buildViewMenu`
  (`client/lib/viewport3d/part_toolbar.dart`, around line 470-580). It has Background Colour, **Body Colour**, **Body
  Transparency**, Polygon Resolution and a **Scene** sub-menu (roughness / light / glow, `SceneControlsPanel`).
- `PartScreen` owns the values (`_bodyColourHex`, `_bodyOpacity`; `_onBodyColourChanged` / `_onBodyOpacityChanged` around line
  11452) and stores them in `ViewPreferences` (`view_body_colour`, `view_body_opacity`, `client/lib/viewport3d/view_preferences.dart`).
- `PartViewport` uses them **only for the primary bodies**, meaning the root Part's own bodies, or the focused Part's bodies
  while something is focused (`_syncMeshNode`, around line 2454 and 2600-2680 of `part_viewport.dart`):
  - colour = `focusOccurrenceColorHex ?? bodyColourHex`, and a painted primary (`primaryLook`) wears its look on top;
  - opacity = `bodyOpacity` (times the Select Other dim).
- **Placed instances ignore both.** `_syncAssemblyInstanceNodes` (around line 2780-2910) builds every sub-part and
  sub-assembly instance with `buildAssemblyInstanceNode` (`mesh_geometry.dart`, around line 1108), whose colour is
  `tint ?? vm.Vector3(0.68, 0.72, 0.78)` (a hard-coded neutral) and whose opacity is only the focus fade
  (`assemblyInstanceOpacity`, 0.25 for context) and the Select Other dim. Painted instances go through
  `buildLookedInstanceNode` with their look. So in an assembly whose root has no bodies of its own, Body Colour and Body
  Transparency do nothing. That is the reported bug.
- Other places that set how a body looks, all of which the override must beat: the Appearance tool's looks
  (`assemblyInstanceLooks`, `primaryLook`, per-face looks; `docs/appearance-tool-scope.md` D3), `Occurrence.color` (the
  tree's colour disc, `instance.color` → `tint`), and a scene's appearance overrides while a scene is shown (`_sceneMode`,
  `docs/scenes-scope.md`: "a scene's appearance beats everything else").

### Change

The View menu's colour and transparency become **one display override** (call it `ViewAppearanceOverride`): a colour, an
opacity and an on/off flag. It is display only. It never writes to the model, a scene, a saved file or an export.

1. **Model.** In `view_preferences.dart` add `ViewAppearanceOverride { bool enabled; String colourHex; double opacity; }`
   (or three statics, following the file's pattern). Use **new** keys (`view_override_colour`, `view_override_opacity`,
   and `view_override_enabled` if Decision 1a goes that way). On first load, seed the colour and opacity from the old
   `view_body_colour` / `view_body_opacity` keys so nobody loses their choice. Leave the old keys alone: the mesh viewer
   (`mesh_viewer_screen.dart:215, 301`) has no paint and keeps using `view_body_colour` as its plain body colour.
2. **The "off" look.** With the override off, an unpainted body should look the same wherever it is. Today the root uses
   `ViewPreferences.defaultBodyColourHex` (`#B0B8C1`) and instances use the hard-coded `(0.68, 0.72, 0.78)`. Make
   `buildAssemblyInstanceNode`'s default `vector4FromHex(ViewPreferences.defaultBodyColourHex).xyz`, and also its roughness
   / metallic so they match `_syncMeshNode` (it uses `0.6` / `0.1` against `widget.roughness` / `ScenePreferences.fixedMetallic`).
   `_syncMeshNode`'s fallback becomes `focusOccurrenceColorHex ?? ViewPreferences.defaultBodyColourHex`. That is the only
   colour change a user with no override will see (the 2% difference between the two greys).
3. **Viewport.** Replace `PartViewport.bodyColourHex` / `bodyOpacity` with one nullable
   `ViewAppearanceOverride? appearanceOverride` (null = off). When it is set:
   - `_syncMeshNode`: skip `primaryLook` (the `looked` branch) and `focusOccurrenceColorHex`. Colour = the override colour.
     Opacity = the override opacity times the Select Other dim, as `bodyOpacity` is now.
   - `_syncAssemblyInstanceNodes`: always use `buildAssemblyInstanceNode` (never `buildLookedInstanceNode`), `tint` = the
     override colour, opacity = `override.opacity * <focus fade>` and then the existing `math.min` with
     `kSelectOtherDimOpacity`. Keep the focus fade: the user can still tell context from the edit target, and Item 2's
     Edit Alone hides context anyway.
   - Scene instances (`_sceneInstances`) go through the same path, so a shown scene is covered with no extra code. Check this
     in a test.
   - Leave alone: live previews (orange), coarse overlays (blue), skipped instances, mate / pattern ghost previews, section
     cut caps, edge colours, selection / hover highlights (`highContrastColorFrom` should read the override colour when it is
     set, and the default otherwise), and reference planes.
   - `didUpdateWidget`'s rebuild check (around line 2042) must compare the new field, and must also rebuild the **assembly
     instance** nodes when it changes (today a body colour change only rebuilds `_syncMeshNode`).
   - Translucency below 1.0 already switches to blend + double-sided winding in both builders. Nothing new is needed there.
4. **Menu** (`_buildViewMenu`). Put the three entries together in one group with a short header, "Override appearance":
   - **Body Colour**: picking a swatch sets the colour **and turns the override on**.
   - **Body Transparency**: setting the slider sets the opacity **and turns the override on**. Moving the slider back to
     opaque does not turn it off; only the button does.
   - **Use model appearance** (a `ListTile` with `Icons.format_color_reset`, or a `SwitchListTile` named "Override
     appearance"; see Decision 1b): turns the override off. Disabled when it is already off.
   - Show the state in the entries' subtitles: "Overriding: #RRGGBB" / "Overriding: 40% see-through" / "Off: showing the
     model's own colours".
   - Add the same three commands to the ribbon's View tab (`_ribbonTabs`, the `id: 'view'` tab around line 25611) so desktop
     and the phone Start menu's View tab have them as well. Today Body Colour is only in the hamburger menu.
5. **Make it obvious when it is on.** A forgotten override hides all the paint, which looks like lost work. While the override
   is on, show a small chip at the top of the viewport ("Appearance override · Turn off"; a tap turns it off), near the
   presenter button / view cube and out of the FAB columns. Hide it while presenting (`_chromeHidden`).
6. **Appearance panel interaction.** While the override is on, painting still writes to the model, but you cannot see the
   result. When the Appearance panel opens with the override on, show a one-line banner in the panel ("View override is on:
   your paint is saved but hidden. Turn off") with a button that turns it off. Do not turn it off by itself.
7. **Out of scope:** the 2D/3D sketch screen's own session Body Colour / Transparency (`sketch_screen.dart`,
   `_orbitBodyColourHex` / `_orbitBodyOpacity`; sketching wants see-through reference bodies, and this works now), the mesh
   viewer, and DIDSA-VR.

### Tests

- `test/part_toolbar_test.dart`: the three entries, their subtitles, picking a colour or opacity reports "override on", Use
  model appearance is disabled when off and reports off.
- `test/view_preferences_test.dart` (or wherever `ViewPreferences.load` is tested): the new keys default from the old ones; an
  explicit new value wins; the old key is not rewritten.
- `test/mesh_geometry_test.dart`: `buildAssemblyInstanceNode`'s default colour equals `defaultBodyColourHex`. That builder is
  GPU-bound, so pull the colour / opacity choice into a pure function (for example
  `resolveInstanceLook({override, look, tint, fade, dim}) → (colour, opacity, useLook)`) and test that function on every
  combination: override on/off × painted/unpainted × tinted/untinted × focused/context × Select Other dim. Do the same for
  the primary bodies (`resolvePrimaryLook`).
- `test/part_screen_test.dart`: picking Body Colour in an assembly with an un-bodied root passes a non-null
  `appearanceOverride` to the viewport; the chip appears and turns it off; the ribbon View tab commands.
- **Cannot be tested here:** that the rendered colour is right on screen (the widget tests skip without a GPU backend). Say so
  in the progress notes.

---

## 2. Edit Alone

### What exists today

- **Make Focus / Exit Focus** (component context menu, `_onOccurrenceLongPress` in `part_screen.dart` around line 24096;
  `AssemblyFocusStack` in `client/lib/assembly/focus_stack.dart`). Pushing focus makes that component's Part the edit target
  (`_focusPartId`), its bodies render opaque, every other instance fades to `kNonPrimaryAssemblyOpacity` (0.25), and hit
  testing only takes instances inside the focus (`part_viewport.dart` around line 5597). The lens is **not** changed, and the
  rest of the assembly stays on screen as faded context. The tree has a breadcrumb back (`AssemblyTreePanel.onExitFocus` →
  `_exitAssemblyFocus`).
- **Isolate** (`_isolateOccurrence`, around line 24831) **writes `hidden` to the backend** for every sibling. That is a model
  change. It is saved with the file and is not what is wanted here.
- Opening a component's file in its own window/screen is the multi-window path the owner wants to avoid on a phone.

### What Edit Alone does

It is Make Focus plus four things: the rest of the assembly is **hidden** (not faded), the **lens follows the target** (Part
lens for a part, Assembly lens for a sub-assembly), the **camera frames the target**, and a **"Back to assembly" button** that
is always on screen ends it. Nothing is written to the backend, so the file is not changed by entering or leaving.

1. **State.** Add an Edit Alone session to `PartScreen`:
   ```dart
   class _EditAloneSession {
     final int baseDepth;                     // _focusStack depth before entering
     final AssemblyLens lensBefore;
     final Map<String, dynamic>? viewpointBefore; // PartViewportState.currentViewpoint()
     final String label;                      // occurrenceDisplayName(...)
     final bool isSubAssembly;
   }
   _EditAloneSession? _editAlone;
   ```
   Do not put it inside `AssemblyFocusStack`: the stack stays a plain focus path, and Edit Alone is screen state on top of it.
2. **Entering** (`_enterEditAlone(OccurrenceDto occurrence)`):
   - Refuse an unresolved component (`resolvedPartId == null`) with the same message Make Focus uses, and refuse while a
     tool, picker, scene (`_sceneMode`) or presentation is active (as `_startPresenting` refuses).
   - Record the session, then `focusStack.push(resolvedPartId, occurrence.id, label)` exactly as the `makeFocus` case does,
     then `await _refreshFocusTargetContent()`.
   - **Sub-assembly or part:** it is a sub-assembly when the (just refreshed) `_occurrences` of the new focus is not empty.
     Use that rather than a guess from the instance list. Set `_lens` to `assembly` or `part` without going through
     `_toggleAssemblyLens`'s flip (add `_setLens(AssemblyLens)` that does the same exit-multi-select / refresh work, and make
     `_toggleAssemblyLens` call it).
   - Frame it: `zoomToFit` after the next frame, once the mesh has updated (see point 3 for the bounds).
   - Clear the selection, close the component drawers and the Select Other UI.
3. **Viewport** (`PartViewport`): add `bool soloFocus` (true while `_editAlone != null`). When it is true:
   - `_syncAssemblyInstanceNodes` and `_syncAssemblyInstanceEdgesNode`: skip every instance where
     `!isOccurrencePathWithinFocus(instance.occurrencePath, focusedPath)`. That includes the root's own `[]` instance, which
     is drawn as context while focused (the "Phase 20 Stage 4" comments at around line 2798 and 3007). Do not skip
     instances inside the focus: a sub-assembly's children must still draw.
   - `_assemblyInstanceBounds()` (used by `_doRecentre`, around line 6430) counts only those instances, so Fit frames the
     target and not the whole assembly. Check that `boundsOfBodies(widget.bodies)` is in the same frame as the instances
     while focused (the primary bodies are drawn with `focusWorldTransformMatrix`). If it is not, transform the bounds by
     the focus matrix.
   - Mate glyphs, the component gizmo, section-preview requests and Measure should already ignore instances outside the
     focus. Check each one and skip hidden instances wherever it does not.
   - Leave the content where it is in world space (it keeps its assembly position). Moving it to the origin would make
     sketches and planes appear to jump. Decision 2b if the owner wants otherwise.
4. **The way back.** A pill at the top centre of the viewport, always shown while in Edit Alone (not hidden by the phone's
   collapsing chrome): "Editing **<label>**" and a **Done** button (icon `Icons.close_fullscreen` or `Icons.arrow_back`;
   tooltip "Back to the assembly"). Also:
   - Android Back / Esc: add it to `_cancelActiveMode`'s order **after** closing open tools, menus and panels, and before
     anything else (so Back first closes a panel, then leaves Edit Alone).
   - The tree breadcrumb's back button while in Edit Alone leaves Edit Alone (not just one level of focus).
   - Desktop ribbon: an **Exit Edit Alone** command in the Assembly tab and the Part tab while active.
5. **Leaving** (`_exitEditAlone()`): pop the focus stack back to `baseDepth` (it may be deeper if the user did Make Focus
   inside Edit Alone, see point 6), `await _refreshFocusTargetContent()`, `_setLens(lensBefore)`,
   `animateToViewpoint(viewpointBefore)` if one was saved, clear `_editAlone`. If the user is mid-tool (an Extrude panel is
   open, a sketch is being edited), cancel the tool first with the usual cancel path, or ask "Discard the open <tool>?" if
   that tool has a confirm-to-discard. Do not leave a preview feature behind in the sub-part.
6. **Inside Edit Alone.** Everything that works while focused still works: Part-lens features target `_focusPartId`, and
   Assembly-lens tools act on the sub-assembly's children. Make Focus / Edit Alone on a child of the sub-assembly pushes
   further; **Done always returns to the assembly the user started from** (`baseDepth`). Do not allow Edit Alone inside Edit
   Alone; it is the same as Make Focus there. Make Exit Focus at `baseDepth + 1` act as Done.
7. **Entry points** (the owner asked for both):
   - **Component context menu** (`showComponentContextMenu`, `component_context_menu.dart`): add
     `ComponentContextMenuAction.editAlone` as the **first** entry ("Edit Alone", `Icons.edit_note` or
     `Icons.open_in_full`), above Make Focus. It opens from a tree row long press (`AssemblyTreePanel.onOccurrenceLongPress`)
     and from a right click, so both are covered.
   - **Selected component in the viewport** (`ComponentSelectionToolbar`, `component_selection_toolbar.dart`): add an
     **Edit** button first (before Move) with an `onEdit` callback. This is the "context option when a component or
     sub-assembly is selected".
   - Pattern copies (`#pattern:` paths) have no Occurrence of their own: offer Edit Alone on the **source** component, or
     hide the entry for a copy. Check what Make Focus does today and do the same.
8. **Saving:** nothing new. Edits inside a sub-part are saved by the existing multi-file save (`assembly/save_all.dart`), as
   they are while focused now.
9. **Naming (Owner):** the new function is **Edit Alone** (menu entry "Edit Alone", the selection toolbar button "Edit
   Alone" or "Edit" where space is short, the pill "Editing <name>" + Done). The existing **Isolate** keeps its name and
   behaviour. Use one constant (`kEditAloneLabel`) for the label.

### Tests

- `test/component_context_menu_test.dart`: the new first entry and its action.
- `test/component_selection_toolbar_test.dart` (new, or in `part_screen_test.dart`): the Edit button calls back.
- `test/part_screen_test.dart` (fake API with an assembly holding one part and one sub-assembly):
  - Edit Alone on a part: focus stack depth +1, lens = Part, `PartViewport.soloFocus` true, the pill shows the label.
  - Edit Alone on a sub-assembly: lens = Assembly, the tree shows its children.
  - Done: depth back to the start, lens restored, `soloFocus` false, and **no `updateOccurrenceHidden` call** at any point
    (no backend writes).
  - Make Focus inside Edit Alone, then Done: back to the start depth in one step.
  - Back / Esc: closes an open panel first, then leaves Edit Alone.
  - Refused while a scene is shown, and for an unresolved component.
- Pure helper for the viewport's skip rule (`soloFocusShowsInstance(path, focusedPath)`), tested on root, sibling, the
  target and the target's grandchild. The node building itself is GPU-bound and skips here.
- **Cannot be tested here:** what it looks and feels like on a phone (framing, the pill's place against the FAB columns).

---

## 3. Sketch origin

### What exists today

- A Sketch's local frame is its anchor plane's basis (`origin`, `x_axis`, `y_axis`, `normal`) with the Sketch's own `flip` /
  `rotation_quarter_turns` on top: backend `basis_for_sketch` (`backend/app/document/create_plane.py` around line 433) and
  `apply_orientation` (`plane_geometry.py`); client `SketchPlaneBasis.withOrientation` (`sketch_geometry_3d.dart`). The
  Sketch's origin Point is local `(0, 0)` (`Sketch.origin_point`, `backend/app/sketch/models.py` around line 1312) and is
  solver-fixed.
- **Fixed plane** (XY / XZ / YZ): origin = world origin. Good, keep it.
- **Sketch on a face**: `_onNewSketchOnFaceTapped` (`part_screen.dart` around line 18635) creates an `offset_face`
  `CreatePlaneFeature` with offset 0 and anchors the Sketch to it. Its origin is whatever OCCT's `gp_Ax3` location for the
  face's surface is (`_resolve_planar_face`, `create_plane.py` line 168). The midplane docstring in the same file records
  that this is **a corner for a box's side faces and the face centre for its top/bottom**, so in practice it is arbitrary.
- **Orientation confirm step**: `_addSketchFeature` → `_pendingOrientation*` state → the bottom pill with rotate / flip /
  Cancel / Continue (`part_screen.dart` around line 27776). The same step re-opens for an existing Sketch from its context
  menu (`_redefineSketchOrientation`, `_PendingOrientationMode.redefine`). That pill is where the origin control goes.
- `PointRef` (`backend/app/document/models.py` line 404) is already "a Body vertex or a Sketch Point", with
  `resolve_point_ref_position` giving the world position (`create_plane.py` around line 689). Line and arc endpoints are
  Sketch Points, and a circle / arc centre is a Sketch Point too, so `PointRef` already covers "sketch points, curve and
  line endpoints". A Body edge's endpoints are Body vertices. The external-reference work already has a circular Body
  edge's centre as a reference kind (`ExternalVertexReference.kind == "circle_centre"`).
- References to Body sub-shapes go through the reference-identity system (`docs/reference-identity-design.md`;
  `FeatureResponseBase.lost_references` / `moved_references` / `followed_references`).

### Model (backend)

1. **Where to store it:** on `SketchFeature` (document layer), not on `Sketch` (`app.sketch`). It references Body geometry,
   which only the document layer resolves, and `basis_for_sketch` already reads the `SketchFeature`. Add:
   ```python
   @dataclass(frozen=True)
   class SketchOrigin:
       point_ref: PointRef | None = None          # Body vertex or Sketch Point
       circle_centre_ref: SubShapeRef | None = None  # a circular Body edge's centre
   # SketchFeature:
   origin: SketchOrigin | None = None   # None = the anchor plane's own origin (today's behaviour)
   ```
   At most one field is set (router-validated, the usual pattern). `None` keeps every existing file and Sketch exactly as it
   is.
2. **Resolving it:** in `basis_for_sketch`, after `apply_orientation`, if `origin` is set, resolve its world point
   (`resolve_point_ref_position`, or the circle centre the way `refresh_external_references` already finds it), **project it
   onto the plane** (`p - dot(p - o, n) * n`) and use that as the basis `origin`. The axes and normal do not change. A point
   off the plane is allowed: its projection is used (useful for a vertex on the far side of a part).
3. **No cycles:** only geometry that exists **before** this Sketch in the feature history can be the origin. `basis_for_sketch`
   is already called with the `bodies` accumulator as of the Sketch's place in the history, so a Body vertex created later
   cannot resolve. For a `sketch_point_ref`: refuse the Sketch itself and any Sketch whose `SketchFeature` comes later in
   `part.features` (422 `origin_reference_not_upstream`). Check this when the origin is set **and** on reorder / rollback
   if those can move a Sketch above its origin's source (look at how `CreatePlaneFeature`'s point refs are guarded and copy
   that).
4. **Lost reference:** do **not** fail the Sketch (that would break every feature after it). Fall back to the anchor plane's
   own origin, and report it through `FeatureResponseBase` as `lost_references: ["origin.point_ref.vertex_ref"]` (or the
   circle-centre path) with the reason, so the tree shows its usual lost-reference badge. Use the same
   signature / history following that other `SubShapeRef`s use (so a vertex that moves to a new index is followed, not
   lost).
5. **API:**
   - `SketchFeatureCreate` gains an optional `origin` (`SketchOriginSchema`), or the special value `"auto"` (see Defaults
     below).
   - New `PATCH /document/parts/{part_id}/features/{feature_id}/sketch-origin` with `{origin: SketchOriginSchema | "auto" |
     null}` (`null` = the plane's own origin). Returns the `SketchFeatureResponse`, which gains `origin` (the stored ref) and
     `resolved_origin: [x, y, z]` (world, after projection) so the client can draw it without working it out again.
   - Mesh / feature responses that embed a Sketch basis pick it up through `basis_for_sketch` with no extra work. Grep for
     every other place that builds a Sketch basis without going through it (the client `SketchPlaneBasis` builders,
     `ai_plan.py`, `gear*` and the AI plan translator) and route them through it.
6. **Native format** (`native_format.py`): write `origin` on the sketch feature only when set. Old files load with `None`. Add
   a round-trip test and an old-file test. DIDSA-VR's `scripts/native_compose.gd` composes `.didsa` files and must keep the
   new key (see 3d).
7. **"auto" is opt-in.** A `SketchFeatureCreate` with no `origin` gets `None` (the plane's own origin, today's behaviour).
   Only a client that sends `"auto"` gets the corner default. So DIDSA-VR, the AI plan and any older client keep working
   unchanged until they choose to send it.

### Defaults ("auto")

When the client creates a Sketch it sends `origin: "auto"`. The backend turns that into a concrete stored reference (or
`None`), so the stored value never changes by itself after creation:

| Anchor | Default origin |
|---|---|
| Fixed plane (XY / XZ / YZ) | `None`: the world origin (today's behaviour) |
| Plane offset from a fixed plane, or from a Plane that ends at one | `None`: the world origin projected (already true today, because offsetting moves the origin along the normal) |
| **A Body face** (New Sketch on Face), or a Plane offset from / parallel to a Body face | **The face's bottom-left corner**: the face's vertices on its outer wire, in the Sketch's **oriented** local frame, the one with the smallest `y`, ties broken by the smallest `x` (tolerance 1e-6 × face size). Stored as a `vertex_ref` |
| A face with no vertices but a circular outer edge (a disc, a cylinder end) | That edge's centre (`circle_centre_ref`) |
| Anything else (three points, midplane, normal to a line / curve / edge, a curved boundary with no vertex) | `None`: the plane's own origin |

**Flip and rotate change which corner is bottom-left.** While the confirm step is open and the user has not picked an origin
by hand, the client re-sends `"auto"` after each flip / rotate (`_adjustPendingOrientation`), so the origin stays at the
bottom-left corner of what they see. After a manual pick, flip / rotate leave the origin alone. Do the corner choice in the
backend (it has the face's topology; the client mesh has no face → vertex map, only `faceEdgeIds`).

### Client

1. **DTOs** (`document_api_client.dart`): `SketchOriginDto`, `FeatureDto.sketchOrigin` / `resolvedSketchOrigin`,
   `createSketchFeature(..., origin: 'auto')`, `updateSketchOrigin(partId, featureId, origin)`.
2. **Basis on the client:** wherever the client builds a Sketch's `SketchPlaneBasis` (`_customPlaneBasis`, `_planeOfFeature`,
   the sketch-geometry refresh, `SketchScreen`'s basis, the orientation indicator), use `resolvedSketchOrigin` as the
   `origin` when it is set. Add `SketchPlaneBasis.withOrigin(vm.Vector3)`. Check that a Sketch's 3D rendering and its Extrude
   line up for a moved origin (that is the classic bug this file's history records for flip / rotate).
3. **A Pick origin button in the orientation step (Owner).** The orientation pill (rotate / flip / Cancel / Continue or Done,
   `part_screen.dart` around line 27776) gets a **Pick origin** button (icon `Icons.my_location`, tooltip "Pick a point for
   the sketch origin"), between flip and Cancel. It is there **in both modes of that step**:
   - **defining** a new Sketch's orientation and flip (`_PendingOrientationMode.newSketch`, from `_addSketchFeature`,
     including New Sketch on Face), and
   - **editing** an existing Sketch's orientation and flip (`_PendingOrientationMode.redefine`, from the Sketch's context
     menu via `_redefineSketchOrientation`; point 4 below covers what changes there).

   Key the button (`ValueKey('sketch-orientation-pick-origin')`) so tests can find it in both modes. Tapping it:
   - enters an "origin pick" sub-mode: push a selection-filter override that allows **vertex**, **sketch point** and
     **edge** (a circular edge picks its centre; a straight edge picks the nearer endpoint to the tap), using the
     `_selectionFilterOverrides.push(...)` pattern the other pickers use. Selection mode is forced off during the step today
     (for orbiting), so the pick sub-mode turns it on and puts it back after;
   - shows a `PickerRibbon` "Tap a corner, point or circle for the sketch origin" with **Plane origin** (sets `null`),
     **Auto** (sets `"auto"`) and Cancel;
   - on a pick, sends `updateSketchOrigin` and returns to the pill. The `SketchOrientationIndicator` (the axes drawn in the
     viewport during the step) moves to the new origin. Draw a small ring at `resolvedSketchOrigin` while the step is open.
   - Only allow Sketch Points from Sketches above this one (the backend refuses others; grey them out in the picker as well,
     using the feature order the client already has).
4. **Editing an existing Sketch's orientation** (`_PendingOrientationMode.redefine`): the same Pick origin button and the
   same picker. On entry, save the Sketch's current origin (`_pendingOrientationOriginalOrigin`, next to
   `_pendingOrientationOriginalFlip` / `Rotation`) and the "auto" flag is off (the stored origin is kept as it is; flip /
   rotate do not move it unless the user taps Auto in the picker). Moving the origin of a Sketch
   that already has geometry **moves the geometry with it**, as flip and rotate do now (local coordinates do not change).
   Points pinned to Body vertices (external references) stay where they are in world space and their local coordinates are
   worked out again, so a Sketch that mixes free and pinned geometry can distort. Show a one-line warning in the ribbon when
   the Sketch has external references, and let Cancel put the old origin back (save it the same way
   `_pendingOrientationOriginal*` saves flip / rotation). See Decision 3b for the "keep the geometry where it is" choice.
5. **Inside the sketcher** (optional, Phase 3c): "Set origin here" on a selected Sketch Point of **this** Sketch moves the
   origin there and **keeps everything where it is** by translating every point by `-p` in one solver transaction. This
   cannot be a live reference (a point in the Sketch cannot define the frame it is drawn in), so it would need a stored fixed
   in-plane offset, `SketchOrigin.offset: (u, v)`, beside the two refs. Build it only if the owner wants it (Decision 3c).

### Phases

- **3a (backend):** model, resolve, auto rule, lost-reference fallback, upstream check, PATCH, native format. Tests in
  `backend/tests/test_sketch_origin.py` (new): fixed plane unchanged; a create with no `origin` stores None even on a face (VR and older clients); face sketch auto = bottom-left corner for the default
  orientation and for each of the 4 rotations × flip on a box face; disc face = centre; a vertex off the plane is projected;
  an Extrude of a rectangle drawn at local `(0, 0)` lands at the chosen corner; a downstream Sketch Point and the Sketch's own
  point are refused; a lost vertex falls back and is reported; a followed vertex is followed; native round trip and old file.
  Needs pythonocc: run in CI or the conda env from `tools/` (earlier sessions could not run the geometry tests in the sandbox,
  so say which tests ran).
- **3b (client):** DTOs, basis plumbing, the Origin button and picker, redefine with Cancel. Tests: `document_api_client_test.dart`
  (parse / send), a `SketchPlaneBasis.withOrigin` unit test, `part_screen_test.dart` (the pill has Pick origin both when
  defining a new Sketch and when editing an existing one's orientation; picking a vertex
  calls `updateSketchOrigin` with a `vertex_ref`; Plane origin sends null; flip after Auto re-sends auto, flip after a manual
  pick does not; redefine Cancel restores the old origin; New Sketch on Face sends `origin: 'auto'`).
- **3c (optional):** Set origin here, inside the sketcher.
- **3d (DIDSA-VR):** see below.

### DIDSA-VR (3d)

Checked against DIDSA-VR `main` at the time of writing. Read that repo's `CLAUDE.md`, `docs/backend-api-notes.md` and
`tests/README.md` first. Work on the branch of the same name there (`ccr-b90afddb-8kqv89`).

**Why it is needed.** DIDSA-VR does not ask the backend for a Sketch's frame. It builds the frame from the plane itself:
`SketchMath.fixed_basis(plane)` for XY / XZ / YZ, or `SketchMath.basis_from_plane_response(<the create_plane Build row>)`
(`scripts/design_table/sketch_math.gd`, line 37), whose `origin` is the **plane's** origin. Today it refuses a Sketch that is
flipped or turned in the flat app ("That sketch is flipped or turned in the flat app...", `table_editor.gd` around line 1190,
and `_plane_for_row` around line 2457). It has **no such check for a moved origin**, so once 3a lands a flat-app Sketch with an
origin would open in VR **shifted**: its curves drawn in the wrong place, and new geometry drawn there landing offset from
where the user put it. The same happens to finished sketches drawn for Loft / Sweep / Pattern picks (`_plane_for_row`,
`_load_sketch_picks`). The picks are by id, so they still pick the right curve, but they are drawn in the wrong place.

**Changes:**

1. **Use the resolved origin.** Wherever DIDSA-VR builds a Sketch's frame from a Build row (`table_editor.gd`'s open-sketch
   path around line 1176-1187, `_plane_for_row`, and `SketchSession.reopen` if it rebuilds one), if the Sketch's row carries
   `resolved_origin` (3a, point 5), replace the basis `origin` with it. That is the only change: the axes and normal stay the
   plane's. Add `SketchMath.with_origin(basis, row)` and test it. A `resolved_origin` of `null` (lost reference) means the
   plane's origin, which is what the backend fell back to as well.
2. **Old backends:** a row with no `resolved_origin` key and no `origin` key is today's Sketch. Leave it as it is.
3. **The `.didsa` file:** check that `scripts/native_compose.gd` copies a sketch feature's dictionary through unchanged (keys
   it does not know survive). Add a test with a sketch feature carrying `origin` (a `vertex_ref` and a `sketch_point_ref`
   case). If the composer remaps ids (occurrence paths, `#pattern:`), check whether it must remap ids inside `origin` too.
   It should not need to, because the refs are Part-local, but confirm it.
4. **New sketches made in VR** (`SketchSession.start`, `scripts/design_table/sketch_session.gd` around line 99-140): on a
   **face** send `"origin": "auto"` in the sketch feature body, so a face sketch gets the same bottom-left corner as in the
   flat app, and use the create response's `resolved_origin` for `plane["origin"]`. On a fixed or created plane send nothing
   (the plane origin, as now). VR has no orientation step and no flip / rotate, so "auto" is worked out once, at creation.
   Picking an origin by hand in VR is **not** in this plan (it would need the orientation step VR does not have); note it as
   open work in VR's `docs/status.md`.
5. **Fake backend:** `tests/helpers/fake_cad.gd` (the sketch-feature create at around line 189) returns `resolved_origin`
   when the request had `origin: "auto"`, so the headless tests cover both paths.
6. **Docs:** add the `origin` / `resolved_origin` fields and the PATCH route to `docs/backend-api-notes.md`, and update
   `docs/status.md`.

**Tests (DIDSA-VR):**
- headless: `SketchMath.with_origin`; opening a Build row with `resolved_origin` puts the session plane's origin there; a row
  without it is unchanged; `native_compose` keeps `origin`; a face sketch sends `"auto"` and a plane sketch does not. Add each
  new file to `tests/run_all.sh` and a row in `tests/README.md`.
- live backend (`tests/ci_e2e.sh`, needs 3a running): make a face sketch with `"auto"`, draw a point at local (0, 0), and
  check it lands on the face's corner in the part's frame. Add it to `tests/e2e_ci_list.txt`.
- **Cannot be tested here:** how it looks and feels on the headset.

---

## Decisions

Answered by the owner on 2026-11-07: 2a, 2c and the origin button's placement (marked **Owner**). The rest are still open,
each with a recommended answer.

- **Owner:** the sketch origin is chosen with a **Pick origin** button in the orientation step, both when defining a new
  Sketch's orientation and flip and when editing an existing Sketch's orientation and flip (Item 3, Client points 3 and 4).

1a. **Is the override's on/off state remembered after the app restarts?** *Recommended: no.* The colour and opacity are
    remembered, but the app always starts with the override off, so painted models never look unpainted by surprise. The
    chip (Item 1, point 5) makes the on state obvious within a session.
1b. **What turns it off: a button or a switch?** *Recommended:* a switch named "Override appearance" at the top of the group
    (on/off in one place, and it can turn the last colour back on), plus the viewport chip's "Turn off". The owner asked for
    a button; the switch is a button that also shows its state.
1c. **Does the override also cover the sketch screen's 3D view?** *Recommended: no.* That screen's see-through bodies are
    deliberate (`kSketchEntryBodyOpacity`).
2a. **Name. Owner: "Edit Alone".** The pill reads "Editing <name>" with a Done button.
2b. **Does the edited component stay where it sits in the assembly, or move to the world origin?** *Recommended: it stays.*
    It is still the same Part in the same place. Moving it would make its planes and sketches seem to jump, and Fit already
    frames it.
2c. **Rename the existing "Isolate"? Owner: no**, it stays "Isolate".
3a. **Bottom-left corner as the face default.** "Corner" needs a rule for which one. *Recommended:* bottom-left as seen in the
    Sketch's orientation (smallest y, then smallest x), and it follows flip / rotate until the user picks one by hand.
3b. **Moving the origin of a Sketch that already has geometry: does the geometry move with it, or stay where it is?**
    *Recommended: it moves* (the same as flip / rotate now; simple and predictable). "Stays where it is" needs every point
    and every dimension to the origin rewritten, and breaks for points pinned to body vertices.
3c. **Build "Set origin here" inside the sketcher (Phase 3c)?** *Recommended: later*, once 3a/3b have been tried on a device.
