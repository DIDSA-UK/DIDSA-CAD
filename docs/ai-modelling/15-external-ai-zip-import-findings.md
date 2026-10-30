# External-AI multi-part zip import - build notes and findings

Session of 2026-10-30. Branch `claude/didsa-cad-external-ai-import-c6e5t6`, PR #324.
Trigger: a multi-part frame (long rail, short rail, post, gusset, assembly)
authored by an external AI via "Share with external AI", returned as a zip of
JSON files.

## What was built

**Zip import** (`client/lib/ai/ai_plan_bundle.dart`, `ai_modelling_screen.dart`)
- "Import plan" accepts `.zip`: one `part_manifest`, one plan per part, one
  assembly plan. Files are classified by content (the plan containing
  `add_component` steps is the assembly; the rest are part plans, taken in
  file-name order and matched to the manifest by position).
- The manifest lands on the existing confirm-parts panel. "Confirm & Generate
  All" then runs the normal part/assembly cycles with the imported plans
  instead of provider turns (`_importedBundle`).
- The assembly's `add_component` `relative_path`s are rewritten to the names
  the parts were actually saved under (matched by `<TYPE_PREFIX>_NNN` against
  the manifest's original prefix), so a collision-avoiding rename doesn't
  break the assembly.
- Retry is disabled for a failed imported plan (re-running a fixed plan can't
  succeed); only a cancelled save is retryable.
- `archive` is now a direct client dependency (was transitive, same locked
  version).

## Findings

1. **Hole-loop corners could not be filleted** (fixed).
   `edge_from_sketch_point`/`edge_from_sketch_line` resolve through a
   provenance map built by `_profile_boundary_shapes` (`extrude.py`), which
   only matched `profile.point_ids` - the outer loop. Corners of
   `profile.inner_loops` (e.g. the inner rectangle of a hollow section drawn
   in the same Sketch, exactly what the prompt recommends) had no entry, so a
   fillet on them failed `edge_selector_no_matching_edges`. The LLM followed
   the documented rules; the validator disagreed with them. Now every loop is
   matched. Revolve shares the function; Sweep passes only the outer wire, so
   hole-loop corners still don't resolve there.
   Test: `test_edge_from_sketch_point_selects_a_corner_of_a_hole_loop`.

2. **The in-app AI's "fix" for finding 1 was a different failure.** It moved
   the inner profile into a second sketch plus a cut, then hit `missing_body`
   on the next fillet (the tube no longer existed as a body after the cut).
   Cause not established - never reproduced, and the failing plan's cut
   parameters were not captured. Worth re-checking now that finding 1 removes
   the reason to take that route.

3. **`move_component` on the grounded first component** (dry run fixed;
   importer not).
   The first component placed in an assembly is auto-`fixed`; the real
   endpoint 422s `occurrence_is_fixed`. The external AI's assembly moved it
   (120 degrees about (1,1,1)), the dry run accepted that, and generation
   failed at step 2 after building step 1. Now the dry run rejects it, and the
   Assembly editing prompt says the first component is the reference frame and
   must not be moved. Not the file extension: `add_component` accepted
   `LONG_RAIL_001.DIDSAprt`. Test:
   `test_move_component_on_the_grounded_first_component_is_rejected_in_the_dry_run`.

## Open / not done

- **The zip importer does not repair finding 3.** An imported assembly that
  moves its first component now fails validation with a clear error. A fix is
  to re-express the whole assembly in the first component's frame: apply the
  inverse of its placement to every other component's placement. Left for the
  planned assembly testing.
- Real end-to-end verification of an imported multi-part zip (Generate All
  through the assembly) has not been done; this session had no Flutter SDK
  that ran, no OpenCascade, and no display. Client behaviour was verified only
  by CI (`ai_plan_bundle_test.dart`, compile of the screen), and the parser
  against the real sample zip in a scratch Dart project.
- Not confirmed: whether `add_component` should also accept `.didsa` where
  `.DIDSAprt` is listed (raised from earlier testing; not reproduced here).

## CI notes

- The first client run failed to compile: `plan` was assigned in two branches
  so Dart stopped promoting it to non-null inside `setState` closures. Fixed
  by binding `final plan = detectedPlan;` after the null check.
- From this sandbox the Actions log download host is blocked; the full job log
  can still be fetched through the GitHub tool with a large `tail_lines` (it
  is saved to a file), then filtered for the failure marker.
