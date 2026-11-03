# Mate "Next" (apply and continue) + non-modal Select Other — investigation & fix plan

Status: **investigated, not implemented** (hand-off document). Source: Flutter-client test report, 2026-11-03 (second batch,
after `docs/pattern-component-bugfix-plan.md`).

| # | Report | Root cause | Size |
|---|--------|------------|------|
| M1 | Mate tool should create the current mate and stay open for the next one (buttons: **Next** / **OK**) | `MatePanel` only has Cancel / Confirm; `_confirmMate` always tears the tool down on success | S |
| S1 | Select Other darkens the screen, covers a lot of it and blocks panning, so you can't see what a row highlights | It is shown as a **modal** route: `showAdaptiveSheet` → `showModalBottomSheet` (phone) or a centred `Dialog` (desktop), both with a dark barrier that also swallows every viewport gesture | M |

Recommended order: M1 first (small, self-contained), then S1.

---

## M1. Mate: "Next" (create and keep the tool open)

### Today

- `client/lib/viewport3d/mate_panel.dart` ~line 563: the button row is `ToolPanelKeys` + **Cancel** + **Confirm**.
  `ToolPanelKeys` maps Enter → `onConfirm`, Esc → `onCancel`.
- `client/lib/viewport3d/part_screen.dart`:
  - `_openMate()` (~4993) resets every Mate field, pushes `_mateSelectionFilter`, and stores `_entitiesBeforeMate`.
  - `_confirmMate()` (~5162) calls `_api.createMate(... solve: ...)` (atomic create+solve), then on success sets
    `_mateActive = false`, pops the selection filter, restores nothing, and refreshes the tree and mesh. On an
    `ApiException` it stays open with `_mateError` set (that part is already right).
  - `_closeMate()` (~5017) restores `_entitiesBeforeMate`.
- Mate edit (`_openMateEdit`, ~23951) is a separate flow and is not affected.

### Change

1. **Split the success path of `_confirmMate`** into `_confirmMate({required bool keepOpen})`:
   - shared: create (unchanged), then `await _refreshAssemblyTree(); await _refreshAssemblyMesh();`
   - `keepOpen == false`: today's teardown (close the tool).
   - `keepOpen == true`: stay in the tool and **reset for the next mate**, via a new `_resetMateForNext()`:
     - clear: `_selectedEntities = {}`, `_mateValue`, `_mateLimitMin/Max`, `_resetWidth()`,
       `_resetMateBranchChoice()` (alignment/flip/branch changes), `_mateError`, `_matePreviewMembers`,
       `_applyMateBranchPreview(null)`;
     - **keep**: `_mateType`, `_mateAllowRotation`, `_mateMovement` / Minimal movement (a run of mates is usually the
       same kind and the same movement preference);
     - keep the selection-filter override pushed (do **not** pop/push again) and keep `_entitiesBeforeMate` so Cancel
       still restores the pre-tool selection.
   - Factor `_openMate`'s field reset into `_resetMateForNext()` + the open-only bits so the two can't drift.
2. **Panel buttons** (`MatePanel`): add `onNext` (nullable, so other hosts/tests are unaffected). Row becomes
   `Cancel | Next | OK` — Next is a `FilledButton.tonal`, OK is the `FilledButton` that was labelled "Confirm" (create
   and close, as today; confirmed rename). Both disabled while
   `saving` or while the picks are incomplete (same gate `_confirmMate` already uses: `_matePicksComplete`).
3. **After at least one Next** in this session the Cancel button reads **Close** (it no longer cancels anything that was
   added) — track `int _mateAppliedCount` (reset in `_openMate`) and pass `cancelLabel` / a `addedCount` to the
   panel. Show a small line "2 mates added" under the buttons so the user sees the Next landed (the tree refresh is
   otherwise the only feedback, and it may be hidden).
4. **Keyboard**: keep Enter = OK (today's meaning). Add Shift+Enter = Next via `ToolPanelKeys` (new optional
   `onNext`, wired in `keyboard_shortcuts.dart`'s registry next to the existing Enter/Esc activators). Low priority — drop
   if it complicates the registry.
5. **Failure while applying**: unchanged — the tool stays open with the error; the picks are kept so the user can fix the
   type/flip and press Next again.
6. Should the **Pattern Component** panel get the same? Not asked; leave it (patterns are rarely authored in runs).

### Tests

- `mate_panel_test.dart`: Next renders only when `onNext` is given; disabled while saving; Cancel label switches to
  Close when `addedCount > 0`; the "N mates added" line.
- `part_screen_test.dart` (fake backend already supports `createMate`): pick two faces → Next → one create call, the
  panel is still open, `selectedEntities` is empty, the mate type is kept; then pick two more → OK → second create call
  and the panel closes. Also: a Next whose create fails keeps the picks and shows the error.

---

## S1. Select Other: non-modal, small, doesn't block the viewport

### Today

- Trigger: `PartViewport.onSelectOtherRequested` (click, then click-and-hold) → `PartScreen._handleSelectOtherRequested`
  (`part_screen.dart` ~2745) → `showSelectOtherSheet` (`select_other_sheet.dart`).
- `showSelectOtherSheet` calls `showAdaptiveSheet` (`client/lib/layout/adaptive_sheet.dart`):
  - phone/tablet → `showModalBottomSheet` (default **barrier `Colors.black54`**: the "darkening"), 30 % initial height,
    up to 50 %;
  - desktop → `showDialog` with a centred `Dialog` up to 560 px wide and 85 % tall, also with a dark barrier, and placed
    in the middle of the viewport — exactly where the user was looking.
- Both are modal routes: the barrier takes every pointer event, so orbit/pan/zoom are impossible while it is open.
- Separately, the viewport already dims every body that isn't the previewed candidate's owner
  (`kSelectOtherDimOpacity`, `part_viewport.dart` ~2297/2461) and highlights the candidate (`highlightOverride`). That dim
  is intended and stays; the problem is the barrier darkening the whole screen on top of it.
- `_selectOtherSheetOpen` already suppresses hover highlighting (`suppressHoverFallback`) and breadcrumbs while open.
- No tests cover Select Other today.

### Change: render it in the screen's own Stack instead of as a route

1. Turn `_SelectOtherSheet` into a public `SelectOtherPanel` widget (same rows, same tap = select & close, long-press /
   hover = preview, same tint on the previewed row) and **delete the `showAdaptiveSheet` call**. `PartScreen` holds the
   state instead of awaiting a route:
   `List<HoverHit>? _selectOtherCandidates; Offset? _selectOtherAnchor;` — `_selectOtherSheetOpen` becomes
   `_selectOtherCandidates != null`.
2. **Placement**
   - Desktop: a compact popup (≈ 280 px wide, max ≈ 320 px tall, scrolls inside) `Positioned` next to the click point
     (`onSelectOtherRequested` is `void Function(List<HoverHit>)` today; widen it to also pass the viewport-local point - both call sites, `_fireSelectOther` (`cursor`) and `selectOtherAtGlobal` (`box.globalToLocal(global)`), already have it), flipped/clamped to
     stay inside the viewport and off the ribbon/tree panes. Like SOLIDWORKS' own Select Other popup.
   - Phone/tablet: a bottom panel inside the viewport `Stack` (same visuals as today's sheet, initial ~25 %, drag to
     resize, max 40 %), **no barrier**. It must clear the FAB column like `SelectionListDrawer` does, and hide the
     selection drawer while open (they occupy the same spot) — `_selectOtherCandidates != null` joins the existing
     drawer gating.
3. **Gestures**: with no barrier the viewport keeps receiving pan / orbit / pinch / wheel. Only the panel's own area
   absorbs pointers. While open:
   - a plain **tap on the viewport closes** Select Other and is **not** treated as a pick (confirmed: avoid an accidental
     selection change while the user was just dismissing) — add a guard at the top of the viewport tap path in
     `PartScreen` (`_toggleSelectedEntity` callers / `onEmptyTap`);
   - drags (pan/orbit) do not close it — the candidate list is camera-independent (entity refs), so the highlight stays
     correct as the view moves;
   - Esc closes it (register with the `ToolPanelKeyScope` registry, or a `CallbackShortcuts` on the panel);
   - an X button in the panel header closes it;
   - a second Select Other gesture replaces the list.
4. **Highlight lifecycle**: `onHighlight(null)` was sent when the route future completed — move it into a single
   `_closeSelectOther()` that clears `_selectOtherCandidates`, `_selectOtherAnchor` and `_selectOtherHighlight`. Call it
   on select, X, Esc, viewport tap, lens switch, tool open (`_clearTransientError`'s call sites are a good list) and
   `dispose`.
5. **Hover preview on desktop**: today rows preview on `MouseRegion` hover; keep it, and clear the preview on
   `onExit` of the whole panel (not only per row), so moving the mouse back to the viewport shows the normal scene.
6. `showAdaptiveSheet` stays for its other callers; only Select Other leaves it.

### Tests (new `client/test/select_other_panel_test.dart` + `part_screen_test.dart`)

- Panel: rows render names from `bodyNames`; tap calls `onSelect` and `onClose`; long-press / hover calls `onHighlight`
  with the entity and `null` on release / exit.
- Screen: trigger via `tester.widget<PartViewport>(...).onSelectOtherRequested!(candidates)`; assert
  `find.byType(ModalBarrier)` finds nothing new; `PartViewport` is still hit-testable (a drag over the viewport reaches
  it — e.g. its pan callback / camera changes); a viewport tap closes the panel and does not change
  `selectedEntities`; Esc closes; `highlightOverride` is set while a row is previewed and cleared on close.
- Desktop layout: the popup is positioned inside the viewport rect near the anchor and is ≤ 320 px tall.

---

## Files touched (expected)

`client/lib/viewport3d/mate_panel.dart`, `client/lib/viewport3d/part_screen.dart`,
`client/lib/viewport3d/keyboard_shortcuts.dart` (optional Shift+Enter), `client/lib/viewport3d/select_other_sheet.dart`
(→ panel widget), `client/lib/viewport3d/part_viewport.dart` (pass the anchor position with
`onSelectOtherRequested`), tests as above. No backend changes.

## Product decisions (confirmed by the tester)

1. The Mate buttons are **Next** (create, stay open for the next mate) and **OK** (create and close) - "Confirm" is
   renamed "OK". Wherever this plan says "Apply", read **Next**.
2. A viewport tap while Select Other is open **only closes it** - it does not pick what was tapped.

## Verification

```
cd client && flutter analyze && flutter test
```
