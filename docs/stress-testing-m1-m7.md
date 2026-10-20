# Stress testing Milestones 1-7 (Appearance, Scenes, STEP colours, Finding moved files)

Simulated user input and hostile data against the flat app, DIDSA-VR and the backend. What a green run means: **nothing threw, every
invariant held, and the model of the rule agreed with the code.** It says nothing about look or feel: no run here judges whether a
control is pleasant, findable or comfortable, and nothing was run on a headset or a phone.

## What was run, and how to repeat it

| Layer | Test | What it does |
|---|---|---|
| Flat app | `client/test/stress/ui_stress_test.dart` | Seeded random taps, double taps, drags, cancelled touches, long presses and typing over the Appearance panel, the Scenes panel and the Review sheet, on 5 environments (360x640 phone, phone with 2x text and dark theme, phone landscape, tablet with 1.3x text, desktop). Hostile hex text, 200 scenes with 2000-character and right-to-left names, 300 references with long paths, a busy panel, every dialog (name, Update / Discard / Stay), mouse / stylus / touch. Asserts no framework exception (overflow included) and that the brush is always a valid appearance. |
| Flat app | `client/test/part_screen_test.dart`, "Appearance and scenes under random user input" | 6 seeds x 250 weighted random operations on the **whole screen** (tree colour disc, Appearance panel, Scenes via the Add flyout, hide by long press, dialogs, stray taps and drags) against the fake backend. Asserts no exception and that nothing invalid was sent. |
| Flat app | `client/test/stress/differential_test.dart` | Seeded random cases answered by the Python reference (`tools/fuzz_differential/generate.py`) must be answered identically by the Dart appearance rule (including `resolveFaces` face by face) and file-lookup rule. Run with several seeds (see below). |
| Flat app + backend | `client/test/live/moved_files_live_test.dart` | Real files and a running backend (see `moved-files-scope.md`). |
| VR | `tests/stress_appearance_scenes.gd` | Full scene, 3 seeds x 400 steps: laser aims at faces, panel rows and empty space; clicks, holds, half presses, double presses, releases with no press; other buttons mid-paint; tool switches; wheel wedges (greyed ones too); Update / Discard / Stay; Save new with odd names; delete; undo / redo; tablet sliders at and past their limits; bad colour text; a backend that starts refusing; calls fired without waiting. |
| VR | `tests/stress_moved_files.gd` | 300 seeded random project folders composed by `native_compose.gd` and compared with a separate model of the rule; cycle, self-reference, deep chain and garbage roots. |
| Backend | `backend/tests/test_stress_appearance_scenes_api.py` | 3 seeds x 200 random operations on the real endpoints (valid and hostile overrides, scenes with odd names and overrides, cascading deletes) with the assembly mesh, glb and STEP exports read back; and every awkward type for `ref_part_id` / `resolved_part_id` through `import/native`. A hostile request must be a 4xx, never a 5xx. |

Repeating the differential run:

```
cd backend && PYTHONPATH=. python ../tools/fuzz_differential/generate.py /tmp/fuzz.json 7 4000
cd ../client && DIDSA_FUZZ_CASES=/tmp/fuzz.json flutter test test/stress/differential_test.dart
```

VR: `GODOT=... "$GODOT" --headless --path . --script res://tests/stress_appearance_scenes.gd -- seed=N steps=N` and
`... stress_moved_files.gd -- worlds=N seed=N`. The differential file can also feed DIDSA-VR's GDScript copies (not done here).

## Findings

Fixed in this round (each now covered by a test that fails without the fix):

1. **Appearance panel overflowed on a phone** (360 px wide at 2x text, and any narrow panel): the colour switch sat beside a fixed
   120 px picker. Below 360 px of panel width the controls now go underneath; the shared tool-panel title row (`ResizableToolPanel`)
   no longer overflows with a long title or large text (affects every tool panel that sets a tooltip).
2. **Review sheet** (my own F3 code): the Locate... / Leave missing buttons overflowed a phone; at 2x text the fixed header (summary
   plus the note) took the whole sheet and the list got no room (190 px overflow); a double tap on Use could re-link twice. The note
   now scrolls with the list, the buttons wrap, and Use / Locate... disable every button while one is being applied.
3. **`import/native` returned a 500 for a `resolved_part_id` that was a list or object** (a hostile or corrupt file; an unhashable
   value reached `in document.parts`). Pre-existing, found by the new `ref_part_id` test. It is now a 422 like `ref_part_id`. A
   non-string `resolved_part_id` such as a number was silently cleared before and is now a 422 too.
4. **Review sheet closing** (defensive): the sheet closed itself with `Navigator.maybePop()` on the screen's context. If the sheet had
   already been dismissed while a Use was still in flight, that would have popped the assembly editor instead. It now closes only
   the sheet's own route. (No test fails without this one: it needs a dismissed sheet and a slow compose to reach.)

Observed, not changed (for you to decide):

- **VR file index caches a file's id by path and modified time in whole seconds.** A file replaced by another with a different id
  within the same second keeps the old id until its time changes. Harmless for hand-edited folders; it made the random-folder test
  need the cache cleared between worlds. The flat app's index uses the platform's finer timestamp.
- **VR and the flat app differ on a clashing id:** VR leaves the second file unresolved ("its part id is already used"), the flat
  app re-mints it. Both were the intended design; noted because a project opened in both behaves differently.
- A bundle-shaped file (an occurrence whose `resolved_part_id` already names a Part in the same file) is never looked up by path or
  id, in either client; its missing files are not reported. Intended (one-file "Save all"), but it means the moved-file rule does not
  help such a file.
- The Scenes and Appearance panels do not debounce their own buttons (a double tap calls the callback twice); the owning screen's
  `busy` flag is what prevents a double send. Checked through the whole-screen test, not individually.
- The new name dialog drops a pasted newline silently (single-line field), as the platform does.

## What this does not cover

Feel and comfort (the laser, the trigger threshold, panel distance, text size in the headset); real touch gestures and a real
keyboard on a device; accessibility (screen reader order, contrast measured, not just that dark and light render); a slow or
dropping network (the fakes answer at once, apart from the "refusing" switch and overlapping calls); the Quest build; STEP files
opened in other CAD programs (the backend test reads them back with OCCT only). Screenshots were not used: in `flutter test` text
renders in a blocks-only test font, so a picture says nothing about readability.
