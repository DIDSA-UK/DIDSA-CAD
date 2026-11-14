# Mates review, shared storage and live sessions: plan

Source: the owner's request of 2026-11-12. Three objectives across the backend, the Flutter client and DIDSA-VR (Godot):
a mates review, server-based storage, and "multi user" (observer and multiplayer design reviews, including a phone
"Cardboard" observer). This plan splits the work into tasks and phases. Each phase is sized for one implementation session
(one PR per repo touched) and names the kind of coding agent it suits.

Written from reading the docs and code on `main` (CAD `b17c61c7`, VR `1e5d188`). **Nothing was run and nothing was seen on a
headset.** Code pointers are symbol names; search for the symbol if a line has moved.

## Decisions (owner, 2026-11-12)

| # | Decision | Answer |
|---|---|---|
| D1 | Rollout order | Mates, then storage, then sessions |
| D2 | Session model | One presenter edits; observers join remotely (over the internet through the existing tunnel) |
| D3 | Storage | A storage service beside the CAD backend; local copy for offline work; version check on sync |
| D4 | Mate preview | The real part glides to the mated position; Cancel glides it back (as SolidWorks does) |
| D5 | Voice | Built in from the first usable session release |
| D6 | Avatars | Head, hands and name tag, one colour per person |
| D7 | Observer tools | Change the observer's own view by default; a Share toggle shows a temporary mark to everyone; nothing is saved |
| D8 | Phone observer | The same Godot project, a second Android export (view-only) |
| D9 | Voice codec | One more add-on exception is allowed: an Opus GDExtension, fetched by a script and never committed, like the OpenXR Vendors plugin |

Still to decide, each at the start of the phase named (recommended answer given there): shared or per-person model scale
(P2), whether the store is its own container or a router in the backend (S0).

## Progress

The implementation session updates this table in its PR.

| Phase | Summary | Repos | State |
|---|---|---|---|
| M0 | Mate benchmark: scaling scenes and first-time accuracy baseline | CAD | Done (PR #354; results: "M0 results" below) |
| M1 | Rigid sets in the group solve | CAD backend | Done (PR #355; results: "M1 results" below) |
| M1.1 | Group solve follow-ups: mate geometry cache, ground-row pruning, one preview budget, missing tests | CAD backend | Done (merged; results: "M1.1 results" below) |
| M2 | Constraint model v8 in the Dart and GDScript mirrors; caps raised | CAD client, VR | Done (merged; caps not raised; results: "M2 results" below) |
| M3 | Glide preview (Flutter and VR), VR edit-mate preview | CAD client, VR | Done (CAD #359 / VR #81; results: "M3 results" below) |
| M4 | Better first guess: type from the picks, pick-point defaults | CAD backend + both clients | Done (merged, CAD #360 / VR #82): the type rule shipped (with Peg in hole); no pick-point rule met the standard, so none shipped (results: "M4 results" below) |
| M4.1 | A Distance previewed where the parts are (SOLIDWORKS' order: parallel, the measured distance, then type the one you want) | CAD backend + both clients | Done (merged with M4; results: "M4.1 results" below) |
| M5 | Rigid sets shown in the tree; "moves as one" cues | CAD client, VR | Done (merged; results: "M5 results" below) |
| S0 | Storage scope doc and spikes | CAD, VR | In review: `docs/shared-storage-scope.md`; the Quest spike is built and waits for the owner's run (results: "S0 results" below) |
| S1 | Project store service | CAD | Done (PR #362: `project-store/`; results: "S1 results" below) |
| S2 | Flutter: server projects, local cache, offline queue, conflicts | CAD client | Done (PR #363 and follow-ups: `client/lib/storage/server/`, `client/lib/home/`; results: "S2 results" below) |
| S3 | VR: server projects, cache, offline | VR | Done in DIDSA-VR PR #85 (open at the time of writing; headless and against the real store, not run on a headset; results: "S3 results" below) |
| S4 | Sync hardening and set-up polish | all | Not started |
| P0 | Session protocol scope; voice, Cardboard and `main.gd` split spikes | CAD, VR | Not started |
| P1 | Session hub service and read-only document sharing | CAD | Not started |
| P2 | VR Host / Join Session, roles, avatars, live model state | VR | Not started |
| P3 | Voice | CAD hub, VR | Not started |
| P4 | Observer tools: drone cursor, own-view edits, Share marks | VR | Not started |
| P5 | Phone (Cardboard) observer export and controller mapping | VR | Not started |
| P6 | Flat app joins a session | CAD client | Later |
| P7 | Hardening: reconnects, many participants, per-device keys | all | Later |

---

## Part 1: Mates review

### What is there (and it is the right direction)

`docs/mate-solution-choice-plan.md`, `docs/constrained-drag-smoothness-study.md` and the code agree:

- **Root choice.** Each mate stores its branch (`alignment`, `secondary_flip`, `branch_source`), starts as Closest, and the
  preview returns `controls`, `resolved` and `alternatives` (Flip, Next solution). Branch-specific residuals keep a drag on
  its branch. A new mate that needs an older `auto` mate flipped is offered (`search_branch_changes`), never done silently.
  Conflicts name the mates (`blocked_by`, `conflicting`). This is SolidWorks' model (alignment, flip dimension, MateXpert).
- **Drag.** Only the mate-graph component of the grabbed part is solved (`discover_component`), warm-started from the
  client's last accepted poses (`reference`), with a local nearest-point solve per frame in Flutter
  (`client/lib/motion/local_retraction.dart`) between backend anchors. That is the standard design (in-process damped
  Newton, warm start, decomposition); the study says so and I agree.
- **Tolerance.** Near-redundant mates are accepted within 0.01 mm and shown amber (`mate_tolerance.py`).

### Gaps against SolidWorks / NX

1. **No rigid sets.** `build_group_model` gives every member 6 variables, including parts that are fully locked to each
   other. A sub-assembly is one member (so it does act as a block), but two top-level parts mated solid do not. SolidWorks
   and NX (the D-Cubed solver) merge mutually fixed parts into one rigid set before solving, and treat a sub-assembly as
   rigid unless it is made flexible. The owner's perception is correct.
2. **Scaling.** Backend `solve_group`: 3.4 / 15 / 46 ms for 1 / 3 / 8 members (smoothness study, F1c). The work is dense
   linear algebra on 6k variables, so it grows roughly with the cube of the group size. Flutter's local solve is off above
   8 members or 64 rows (`kLocalMaxMembers`, `kLocalMaxRows`; the gear-train demo is already over), VR's GDScript solver is
   not used at all (12 to 70 ms a frame). `search_branch_changes` (24 solves) and `alternatives` (4 solves) multiply the
   cost per preview. A 30-part bolted frame is one component today; with rigid sets it is one or two bodies.
3. **Preview is a ghost.** The part stays put and a translucent copy shows the result. SolidWorks moves the real component
   as a preview and restores it on cancel. VR has no preview when editing a mate.
4. **First guess.** 83.3% right first time on the bench (`mate-solution-choice-plan.md`, Phase 4). Same-facing distances
   (inset or overhang) 54%; parts started far from their orientation are the other large miss. Interference tie-breaks were
   measured and dropped; do not repeat them.
5. **Mate type is not guessed from the picks.** `_mateType = kMateTypes.first` in `part_screen.dart`; no inference was found
   by search in either client (not confirmed by running the apps).

### M0. Benchmark first (CAD backend; small; standard agent)

Extend the existing mate bench and `backend/tests/motion_scenes.py`:
- scaling scenes: a chain of N bolted plates (N = 5, 10, 20, 50), a frame of N bars with redundant mates, a mechanism
  (4-bar linkage) carrying a 20-part rigid payload;
- record `solve_group`, preview (with alternatives) and drag-anchor times, and how often the client model is refused by the
  caps;
- first-time accuracy scenes for M4: same-facing inset / overhang with realistic pick points, and upside-down starts.

Done when the numbers are in this doc's M0 section. Every later mates phase is judged against them.

### M0 results (2026-11-12)

Measured by `backend/tests/bench_mates_m0.py` (scenes: `tests/motion_scaling_scenes.py`, `tests/mate_first_guess_scenes.py`; the fast
scene test is `tests/test_mates_m0_scenes.py`). No solver code was changed. Reproduce from `backend/` in the `backend/environment.yml`
conda env: `CAD_API_KEY=test-api-key python -m tests.bench_mates_m0 scaling` (about 2 hours on this machine: the 50-plate chain and the
30-bar frame alone take 10 to 20 minutes a variant; `--quick` keeps the small sizes) and `... accuracy --trials 60` (a few minutes).

Machine: Intel(R) Xeon(R) Processor @ 2.10GHz, 4 cores, 15.7 GB, Linux 6.18.44-fc-v378; Python 3.11.18, numpy 2.4.6, OCCT 8.0.1.2. Date: 2026-11-12.

**How to read it.** One run on one shared 4-core cloud VM: compare later runs only with a run on the same machine. Times are medians of up
to 7 runs (5 for previews), in-process through FastAPI's `TestClient` (no network, no tunnel). A scene is built at its true pose, so every
mate is satisfied as built. "Floating" = nothing fixed; "fixed" = the scene's base part fixed. The dof column is the group's own dof as
the analysis reports it; it matched the dof each scene was designed to have in every row.

**Method note: the Phase 4 "mate bench" was rebuilt, not found.** It is not in the repo or its git history (only `bench_width_mate.py` and
`bench_pattern_follower_drag.py` are, and they measure other things). The accuracy half below follows the method in
`mate-solution-choice-plan.md` (ground truth by construction, near 12 mm / 25 deg, medium 50 mm / 100 deg, far 110 mm / any way up, 60
trials, nothing named, extra clicks = the fewer of branch toggles and Next-solution presses), but the doc gives the sizes of only some
scenes, so the others are my choice. **The numbers are therefore a new baseline for M4 to be judged against, not a re-measurement of the
doc's 83.3 %.** Mine is lower (75.9 % on the nine Phase 4 mates; 83.3 % there); the difference is most likely the scenes, which I could not
check against the original.

### Scaling: the group, `solve_group`, the drag anchor and the client caps

Client caps: kLocalMaxMembers = 8, kLocalMaxRows = 64. Times: median ms.

| scene | variant | members | mates | rows | dof | solve_group at rest | solve_group with a wish (iterations) | drag anchor: wall (server solve_ms), max | client model: members / rows | refused by the caps |
|---|---|---|---|---|---|---|---|---|---|---|
| chain-5 | floating | 5 | 12 | 64 | 6 | 9.64 | 32.5 (3) | 41.2 (36.1), 55.8 | 5 / 64 | no |
| chain-5 | fixed | 4 | 12 | 64 | 0 | 7.54 | 45.0 (3) | 36.5 (31.2), 39.2 | 4 / 64 | no |
| chain-10 | floating | 10 | 27 | 144 | 6 | 23.5 | 88.2 (3) | 93.8 (88.9), 107 | 10 / 144 | **yes** (members 10 > 8, rows 144 > 64) |
| chain-10 | fixed | 9 | 27 | 144 | 0 | 31.9 | 78.7 (3) | 83.5 (78.3), 121 | 9 / 144 | **yes** (members 9 > 8, rows 144 > 64) |
| chain-20 | floating | 20 | 57 | 304 | 6 | 60.0 | 239 (4) | 237 (231), 272 | 20 / 304 | **yes** (members 20 > 8, rows 304 > 64) |
| chain-20 | fixed | 19 | 57 | 304 | 0 | 88.2 | 243 (3) | 246 (241), 293 | 19 / 304 | **yes** (members 19 > 8, rows 304 > 64) |
| chain-50 | floating | 50 | 147 | 784 | 6 | 224 | 780 (4) | 894 (883), 1012 | 50 / 784 | **yes** (members 50 > 8, rows 784 > 64) |
| chain-50 | fixed | 49 | 147 | 784 | 0 | 234 | 843 (3) | 829 (823), 884 | 49 / 784 | **yes** (members 49 > 8, rows 784 > 64) |
| chain-5-bolts | floating | 13 | 28 | 144 | 14 | 22.4 | 79.4 (3) | 102 (95.8), 106 | 13 / 144 | **yes** (members 13 > 8, rows 144 > 64) |
| chain-5-bolts | fixed | 10 | 24 | 124 | 6 | 20.0 | 78.1 (6) | 84.4 (80.4), 136 | 10 / 124 | **yes** (members 10 > 8, rows 124 > 64) |
| chain-10-bolts | floating | 28 | 63 | 324 | 24 | 89.8 | 270 (3) | 267 (256), 341 | 28 / 324 | **yes** (members 28 > 8, rows 324 > 64) |
| chain-10-bolts | fixed | 25 | 59 | 304 | 16 | 73.8 | 238 (6) | 306 (298), 364 | 25 / 304 | **yes** (members 25 > 8, rows 304 > 64) |
| frame-4 | floating | 4 | 11 | 44 | 6 | 7.36 | 37.1 (4) | 33.7 (28.5), 43.2 | 4 / 44 | no |
| frame-4 | fixed | 3 | 11 | 44 | 0 | 8.10 | 19.9 (1) | 26.0 (20.3), 32.4 | 3 / 44 | no |
| frame-10 | floating | 10 | 41 | 164 | 6 | 30.8 | 107 (4) | 117 (112), 128 | 10 / 164 | **yes** (members 10 > 8, rows 164 > 64) |
| frame-10 | fixed | 9 | 41 | 164 | 0 | 32.3 | 83.2 (1) | 86.3 (81.3), 94.4 | 9 / 164 | **yes** (members 9 > 8, rows 164 > 64) |
| frame-20 | floating | 20 | 91 | 364 | 6 | 98.1 | 333 (5) | 322 (315), 441 | 20 / 364 | **yes** (members 20 > 8, rows 364 > 64) |
| frame-20 | fixed | 19 | 91 | 364 | 0 | 97.0 | 221 (1) | 234 (228), 250 | 19 / 364 | **yes** (members 19 > 8, rows 364 > 64) |
| frame-30 | floating | 30 | 141 | 564 | 6 | 144 | 557 (5) | 574 (566), 717 | 30 / 564 | **yes** (members 30 > 8, rows 564 > 64) |
| frame-30 | fixed | 29 | 141 | 564 | 0 | 146 | 404 (1) | 388 (384), 424 | 29 / 564 | **yes** (members 29 > 8, rows 564 > 64) |
| linkage-payload-20 | floating | 24 | 68 | 280 | 7 | 74.8 | 217 (3) | 273 (266), 351 | 24 / 280 | **yes** (members 24 > 8, rows 280 > 64) |
| linkage-payload-20 | fixed | 23 | 68 | 280 | 1 | 62.2 | 273 (6) | 261 (257), 285 | 23 / 280 | **yes** (members 23 > 8, rows 280 > 64) |

### Scaling: `preview-mate-solve` (alternatives and the branch search included)

Per cell: median ms / `solve_group` calls in that one preview (largest group solved, members). `auto` = only the mated part moves if that is enough; `group` = the whole component is solved.

| scene | variant | probe/auto | probe/group | redundant/auto | redundant/group | conflict/auto | conflict/group |
|---|---|---|---|---|---|---|---|
| chain-5 | floating | 16.5 / 6 (1) | 71.1 / 6 (6) | 1857 / 9 (5) | 1879 / 6 (5) | 5699 / 28 (5) x | 5891 / 14 (5) x |
| chain-5 | fixed | 17.5 / 6 (1) | 79.3 / 6 (5) | 396 / 9 (4) | 407 / 6 (4) | 3674 / 28 (4) x | 3411 / 14 (4) x |
| chain-10 | floating | 15.0 / 6 (1) | 147 / 6 (11) | 1923 / 9 (10) | 2068 / 6 (10) | 9172 / 28 (10) x | 9482 / 14 (10) x |
| chain-10 | fixed | 16.1 / 6 (1) | 138 / 6 (10) | 1316 / 9 (9) | 1401 / 6 (9) | 10364 / 28 (9) x | 9543 / 14 (9) x |
| chain-20 | floating | 16.3 / 6 (1) | 424 / 6 (21) | 7680 / 9 (20) | 7400 / 6 (20) | 34726 / 28 (20) x | 35729 / 14 (20) x |
| chain-20 | fixed | 20.4 / 6 (1) | 392 / 6 (20) | 6335 / 9 (19) | 6366 / 6 (19) | 40460 / 28 (19) x | 39728 / 14 (19) x |
| chain-50 | floating | 20.8 / 6 (1) | 1729 / 6 (51) | 20990 / 9 (50) | 22113 / 6 (50) | 130233 / 28 (50) x | 132797 / 14 (50) x |
| chain-50 | fixed | 15.9 / 6 (1) | 1304 / 6 (50) | 23421 / 9 (49) | 23840 / 6 (49) | 151611 / 28 (49) x | 153458 / 14 (49) x |
| chain-5-bolts | floating | 15.4 / 6 (1) | 154 / 6 (14) | 4695 / 9 (13) | 4477 / 6 (13) | 14525 / 28 (13) x | 13814 / 14 (13) x |
| chain-5-bolts | fixed | 14.2 / 6 (1) | 115 / 6 (11) | 898 / 9 (10) | 857 / 6 (10) | 7937 / 28 (10) x | 7924 / 14 (10) x |
| chain-10-bolts | floating | 18.2 / 6 (1) | 533 / 6 (29) | 13049 / 9 (28) | 13379 / 6 (28) | 35622 / 28 (28) x | 33253 / 14 (28) x |
| chain-10-bolts | fixed | 17.3 / 6 (1) | 418 / 6 (26) | 5745 / 9 (25) | 5911 / 6 (25) | 40096 / 28 (25) x | 39655 / 14 (25) x |
| frame-4 | floating | 18.8 / 6 (1) | 59.4 / 6 (5) | 2082 / 9 (4) | 1893 / 6 (4) | 12248 / 28 (4) x | 12630 / 14 (4) x |
| frame-4 | fixed | 15.3 / 6 (1) | 64.6 / 6 (4) | 2464 / 9 (3) | 2226 / 6 (3) | 11519 / 28 (3) x | 11029 / 14 (3) x |
| frame-10 | floating | 14.2 / 6 (1) | 188 / 6 (11) | 8274 / 9 (10) | 7592 / 6 (10) | 49113 / 28 (10) x | 47428 / 14 (10) x |
| frame-10 | fixed | 14.6 / 6 (1) | 197 / 6 (10) | 7284 / 9 (9) | 7037 / 6 (9) | 42273 / 28 (9) x | 43618 / 14 (9) x |
| frame-20 | floating | 12.9 / 6 (1) | 571 / 6 (21) | 25149 / 9 (20) | 24970 / 6 (20) | 138781 / 28 (20) x | 142870 / 14 (20) x |
| frame-20 | fixed | 15.7 / 6 (1) | 514 / 6 (20) | 23996 / 9 (19) | 23482 / 6 (19) | 132557 / 28 (19) x | 129115 / 14 (19) x |
| frame-30 | floating | 14.0 / 6 (1) | 1132 / 6 (31) | 41977 / 9 (30) | 42799 / 6 (30) | 235790 / 28 (30) x | 231952 / 14 (30) x |
| frame-30 | fixed | 15.6 / 6 (1) | 896 / 6 (30) | 39155 / 9 (29) | 37372 / 6 (29) | 198721 / 28 (29) x | 191932 / 14 (29) x |
| linkage-payload-20 | floating | 15.2 / 6 (1) | 412 / 6 (25) | 1240 / 9 (24) | 1529 / 6 (24) | 6783 / 28 (24) x | 5685 / 14 (24) x |
| linkage-payload-20 | fixed | 15.9 / 6 (1) | 412 / 6 (24) | 1013 / 9 (23) | 1025 / 6 (23) | 4754 / 28 (23) x | 4397 / 14 (23) x |

`x` = no placement (expected for `conflict`: the answer names the conflicting mates instead).

Client model refused by the caps: 18 of 22 scene variants.


### First-time accuracy of an unnamed mate (60 trials per scene and start class)

Right first time, per start class; `all` = near + medium + far (the Phase 4 bench's three classes). Extra clicks per mate over the same three.

| scene | set | kind | near | medium | far | upside_down | all | extra clicks | no way to the truth | median preview ms |
|---|---|---|---|---|---|---|---|---|---|---|
| stack | phase4 | other | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% | 0.000 | 0 | 10.4 |
| parallel | phase4 | other | 100.0% | 53.3% | 63.3% | 0.0% | 72.2% | 0.278 | 0 | 10.6 |
| pin-in-post | phase4 | other | 100.0% | 56.7% | 80.0% | 0.0% | 78.9% | 0.211 | 0 | 11.8 |
| axis-distance-25 | phase4 | other | 100.0% | 65.0% | 71.7% | 0.0% | 78.9% | 0.211 | 0 | 13.6 |
| inset-10 | phase4 | same_facing | 95.0% | 36.7% | 46.7% | 0.0% | 59.4% | 0.500 | 0 | 19.8 |
| overhang-3 | phase4 | same_facing | 55.0% | 23.3% | 38.3% | 0.0% | 38.9% | 0.611 | 0 | 19.3 |
| gap-6-above | phase4 | facing_gap | 100.0% | 58.3% | 70.0% | 0.0% | 76.1% | 0.333 | 0 | 18.6 |
| gap-6-under | phase4 | facing_gap | 100.0% | 68.3% | 66.7% | 0.0% | 78.3% | 0.333 | 0 | 18.0 |
| vertex-6-above | phase4 | facing_gap | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% | 0.000 | 0 | 11.0 |
| inset-2 | m4 | same_facing | 70.0% | 38.3% | 45.0% | 0.0% | 51.1% | 0.600 | 0 | 19.3 |
| overhang-25 | m4 | same_facing | 100.0% | 30.0% | 43.3% | 0.0% | 57.8% | 0.422 | 0 | 20.8 |
| inset-10-seated | m4 | same_facing, seated | 100.0% | 100.0% | 100.0% | n/a | 100.0% | 0.000 | 0 | 20.3 |
| overhang-3-seated | m4 | same_facing, seated | 100.0% | 100.0% | 100.0% | n/a | 100.0% | 0.000 | 0 | 19.7 |

| summary | right first time | extra clicks per mate |
|---|---|---|
| Phase 4 set (9 mates), near + medium + far | 75.9% | 0.275 |
| Phase 4 set, near | 94.4% | 0.056 |
| Phase 4 set, medium | 62.4% | 0.422 |
| Phase 4 set, far | 70.7% | 0.348 |
| Same-facing distances (all 6 scenes), near + medium + far | 67.9% | 0.356 |
| Same-facing, free part (4 scenes), near + medium + far | 51.8% | 0.533 |
| Same-facing, seated (2 scenes), near + medium + far | 100.0% | 0.000 |
| Same-facing insets only, near + medium + far | 70.2% | 0.367 |
| Same-facing overhangs only, near + medium + far | 65.6% | 0.344 |
| Upside-down starts, every free scene (11) | 18.2% | 1.047 |
| Upside-down starts, same-facing distances (4) | 0.0% | 1.500 |
| Upside-down starts, the other mates (7) | 28.6% | 0.788 |
| Every scene and start class | 63.5% | 0.440 |


### M0 findings (what the numbers say; nothing here was tuned or fixed)

- **Cost grows faster than linearly with the group.** `solve_group` at rest on the bolted chain: 9.6 / 23.5 / 60 / 224 ms for 5 / 10 / 20 / 50
  members (10x the members, 23x the time). With a wish it is 32 / 88 / 239 / 780 ms. The drag anchor (`mate-motion`) tracks the with-wish solve
  (41 / 94 / 237 / 894 ms), so a group of 10 or more members is already beyond the ~150 ms anchor budget the smoothness study designed for,
  and the 20-member groups are around 250 ms. The 20-part rigid payload on a 4-bar linkage costs 75 ms at rest and about 270 ms per anchor.
  Floating or fixed makes little difference at this size.
- **The Flutter caps refuse 18 of the 22 scene variants.** Only `chain-5` (5 members, 64 rows: exactly at `kLocalMaxRows`) and `frame-4`
  fit, floating or fixed. Every other scene exceeds both caps, by rows first (10 members is already 144 to 164 rows). Even a 5-plate chain
  is at the row limit. Redundant mates inflate rows without adding members: `frame-10` has 164 rows against `chain-10`'s 144. So raising
  `kLocalMaxMembers` alone would not help; rows are the binding cap.
- **A preview that moves only the new part is cheap; one that touches the group is not.** `probe/auto` (a loose part onto the group) is
  13 to 23 ms at every size (a 1-member solve each time). `probe/group` grows with the group: 71 ms at 5 plates, 1.7 s at 50, 1.1 s for the
  30-bar frame. Six `solve_group` calls per preview in both.
- **A redundant mate is slow even in a small group.** The `redundant` preview (a distance the locked group already meets) took 0.4 to 1.9 s on a
  5-plate chain, 7 to 8 s on a 20-plate chain and a 10-bar frame, and 21 to 43 s at 50 plates / 30 bars, in 9 solves (`auto`) or 6 (`group`):
  several times what one solve of the same group costs at rest. I did not investigate why (not measured: where in the solve the time goes).
- **A conflicting mate can take minutes.** The `conflict` preview (nothing can meet it, so the branch search and the conflict step run, 28
  solves in `auto`, 14 in `group`) took 3.4 to 6 s on 5 members, 9 to 10 s on a 10-plate chain, 42 to 49 s on the 10-bar frame (redundant mates
  make it slower than the chain of the same size), 35 to 40 s at 20 plates, 2 to 2.5 minutes at 50 plates and at the 20-bar frame, and 3 to 4
  minutes at the 30-bar frame (190 to 236 s). `BRANCH_SEARCH_SECONDS` is 1.5 s in the code, but the clock only ends a search after its minimum of
  `BRANCH_SEARCH_MIN_SOLVES = 8` solves and the conflict step has its own reserve, so on a big rigid group the budget does not bound the wait.
  The route returned an answer (`mate_conflict`) every time.
- **Accuracy baseline (rebuilt bench).** Right first time, near + medium + far: 75.9 % on the nine Phase 4 mates (near 94.4, medium 62.4,
  far 70.7), 0.275 extra clicks per mate. Same-facing distances on a free part (inset 10, overhang 3, inset 2, overhang 25): 51.8 % (doc: 54 %).
  The same four with the part already resting on the base (a stored coincident mate) are 100 %: the stored mate leaves only a slide, so the
  nearest root is right. The big miss is the upside-down start: **18.2 % over the 11 free scenes, 0 % for every same-facing distance**, about one
  extra click per mate (1.5 for same-facing). Only the vertex-to-face gap and the stack coincident are right when the part starts upside down.
- **Pick points are recorded but unused.** `GuessScene.picks` holds a realistic pick per face (and each trial's jittered picks are stored in
  the raw JSON, `--json`), but the backend does not read pick points yet: this baseline is what M4 must beat with them.

### What was not measured or not verified

- **The Dart client was not run.** "Refused by the caps" is computed with the Python reference model (`ConstraintModel`, the one the golden
  vectors pin) at identity poses plus one row per limit mate, compared with `kLocalMaxMembers` / `kLocalMaxRows` read from
  `local_retraction.dart`. That mirrors `LocalRetractor.tryParse`'s checks but I did not run `tryParse`. The GDScript solver was not measured.
- **No client frame time, no network or tunnel time, no headset.** All times are server-side in-process on one VM; a repeat run on another
  machine will differ. Single run, no confidence interval beyond the min and max in the raw JSON.
- **Accuracy scenes are mine.** The 13 scenes (9 from the Phase 4 doc, 4 more same-facing) and the `upside_down` class are new; the
  upside-down starts turn the part 180 degrees about an axis in the mate's plane plus up to 20 degrees of tilt and move it 30 mm. Not
  compared with the original bench because it could not be found.
- **Scaling scenes use boxes, plates with round holes and cylinders only**, with coincident, concentric and distance mates. No gears, limits,
  couplers or pattern followers, and no sub-assemblies.
- Time per scene is dominated by the preview cases; the raw per-case counts (`solves`, `alternatives`, `blocked_by`) are in the `--json` output,
  not in this doc.

### M1. Rigid sets (CAD backend; large; strongest agent, solver maths)

- **Detect.** After `analyze_model`, members whose relative motion is zero in every nullspace vector form a rigid set
  (exact; reuses the SVD basis already computed). A cheaper first pass: two members whose shared mates alone have rank 6.
  A set that contains a frozen member (fixed, or the `""` ref) is frozen. Cache per part revision; invalidate on any mate,
  fix or suppress change.
- **Reduce.** Solve with one 6-variable body per set; members keep a constant offset from the set's lead member. Mates
  inside a set drop out of the solve (they are checked once for `status`). Couplers, limits and pattern followers are never
  merged across.
- **Report.** `constraint_status` / the mates listing gain `rigid_set` (an id per occurrence). `GroupSolveResult.poses`
  still lists every occurrence, so existing clients keep working unchanged.
- **Constraint model v8** (emitted only when a set exists, like v4 to v7): members are the sets; each carries its followers
  as fixed offsets. Golden vectors in `docs/motion/vectors.json` via `tools/motion_vectors/generate.py`.
- **Branch search and alternatives** run on the reduced model.

Tests: the M0 scenes give the same poses as before to 1e-9; a locked pair reports one set; flexing a set (suppress one
mate) splits it; legacy fixtures (`table_top_frame`, the platform) keep their poses; the 50-plate chain solves in the time
of a 1 to 2 member group.

Risk: a set locked only by near-redundant mates (amber). Rule: `near` mates count as locking; a broken mate does not.

### M1 results (2026-11-13)

Code: `backend/app/document/rigid_sets.py` (detection, reduction, expansion), wired into `assembly_group.solve_group` and
`constraint_report`; constraint model v8 in `constraint_model.py` (`RigidMetric`, `expand_rigid_sets`); `rigid_set` on
`GET .../constraint-status` and `GET .../mates`. Tests: `tests/test_rigid_sets.py`. Golden vectors: `local-rigid-*` (4 cases).

**What was built, and where it differs from the M1 bullets above.**
- *Detect.* Exact, in two passes at the base poses: pairs of members whose shared locking mates have rank 6 (and members with rank 6
  to the ground) first, then the nullspace of every locking row on those bodies (relative twist zero in every nullspace vector =
  one set). A mate locks when it is met or `near` (amber); a broken mate, a coupler, a limit and a preview's hypothetical new mate do
  not lock. Members a coupler or a limit touches, and the source of a followed pattern copy, never join a set. Cached per component
  state (members, frozen peers, every mate with its resolved geometry and branch, stored poses): any mate, fix, suppress, geometry
  or stored-pose change misses. There is no part revision counter in the model, so the key is that state, not a revision.
- *Frozen sets.* Every member locked to the ground is put in ONE set, but it is still solved as a 6-variable body held by its mates
  to the fixed parts (not removed from the variables as the bullet says): the same answers, and no side ever has to be re-oriented
  onto a frozen pose. It reports no `rigid_set` id (nothing in it moves; its members read `fully_constrained`).
- *Reduce.* One body per set, its lead the grabbed member (or the set's first member); every mate side on a follower is re-expressed
  in the lead's frame, and the mates inside a set drop out. **A set weighs what its members would** (`RigidMetric`: the 6x6 sum of
  the members' metrics in the lead's chart, Cholesky-factored); with the lead's weight alone a 20-part payload would weigh like one
  part and the nearest-point answers would change. The mates inside the sets are checked once on the expanded poses: a miss beyond
  the near limits is `converged: false` at once; an amber miss gets the unreduced Gauss-Newton steps from the expanded poses, so the
  least-squares share-out between disagreeing mates is what it was (without that, the platform module ended with 4 amber mates at
  0.0077 mm instead of 8 at 0.0039).
- *Report.* `GroupSolveResult.poses`, the analysis' `member_ids` / `basis` / `mobility` and every route still list every member (a
  follower's basis block is its lead's twist moved to its origin; the rows stay orthonormal in the full metric). New:
  `GroupSolveResult.rigid_sets`, `solved_bodies`; `rigid_set` per occurrence (constraint status) and per mate (the listing: the set a
  mate lies inside). `sigma_min` / `sigma_gap` are now the reduced model's (the mates inside a set are not in it).
- *v8.* Emitted only when a set exists; members = leads, `rigid_sets` = each lead's followers with their offsets; the metric and the
  followers' rest-pose wishes are specified in `docs/motion/projector-spec.md` §4b (Version 8). The shipped clients were read, not
  changed: `LocalRetractor.tryParse` (`client/lib/motion/local_retraction.dart`) and `try_parse` (`DIDSA-VR`
  `scripts/motion/local_retraction.gd`) accept versions 3 to 7 and return null for 8, so they keep projecting. Two consequences until
  M2: a group with a set no longer gets the Flutter local retraction even where it fitted before (chain-5, frame-4), and the VR limit
  stop (`mates_tool.gd` `_adopt_limit_model`, which reads limit mates from the parsed model) sees no model for a group that has both a
  limit and a set.
- *Branch search and alternatives* run on the reduced model with no change of their own: they call `solve_group`, which reduces.

**Same answers (the plan's tests).** At rest, every M0 scene (chain, bolted chain, frame, linkage; floating and fixed) gives the same
poses as the unreduced solve to 1e-9, the same dof and mobility and the same free-motion space. With a wish, where the answer is
unique (a rigid chain or frame) the poses agree to 1e-7 (the solver tolerance `_SOLVE_TOL`), not 1e-9; where followers keep free
motion of their own (a bolt's spin, the linkage) the two solves reach the same weighted distance to the wish (equal to 1e-8 relative)
by different paths, and the poses then differ by up to 2.4e-3 in directions the follower weight barely sees: **1e-9 pose parity is not
achievable there.** Legacy fixtures: `table_top_frame` keeps its poses (1e-9) and statuses; the platform's module plan
(`plt-platform-6m-25t`, 93 mates replayed as the app builds them) ends with identical poses (4e-12 mm), 85 ok + 8 near at 0.00385 mm as
before, in 9.3 s instead of 21.9 s. A locked pair reports one set; suppressing one of its mates splits it.

**Benchmark.** `python -m tests.bench_mates_m0 accuracy` then `scaling`, run first on `main` (`3643492`) and then on this branch, on
the same machine (Intel Xeon @ 2.10GHz, 4 cores, Linux 6.18.44; Python 3.11.18, numpy 2.4.6, OCCT 8.0.1.2), both pinned to the same 2
cores (`taskset -c 0,1`, 2 BLAS threads) while other work ran on the other 2. These are the numbers to compare with each other, not
with the M0 section (another machine, 4 cores). Medians, ms.

**Accuracy: unchanged.** All 50 scene x start-class rows identical (right first time, extra clicks, unreachable, not converged); median
preview 17.1 → 16.4 ms.

Scaling (the drag anchor is `mate-motion`'s own `solve_ms`; "bodies" = what the solve had, one per set plus every other member;
client model = the exported model against kLocalMaxMembers 8 / kLocalMaxRows 64, its rows at identity poses as in M0):

| scene | variant | members | bodies (sets) | rest ms before / after | wish ms before / after | drag anchor server ms before / after | speed-up (drag) | client model before: members / rows | after: members / rows (followers) | fits the caps after |
|---|---|---|---|---|---|---|---|---|---|---|
| chain-5 | floating | 5 | 1 (1) | 10.2 / 7.53 | 34.2 / 9.98 | 43.5 / 10.1 | 4.3x | 5 / 64 | 1 / 0 (4) | yes |
| chain-5 | fixed | 4 | 1 (0) | 10.6 / 7.87 | 32.8 / 15.8 | 33.9 / 16.7 | 2.0x | 4 / 64 | 1 / 16 (3) | yes |
| chain-10 | floating | 10 | 1 (1) | 24.1 / 13.2 | 85.2 / 15.8 | 86.8 / 17.1 | 5.1x | 10 / 144 | 1 / 0 (9) | yes |
| chain-10 | fixed | 9 | 1 (0) | 22.9 / 13.5 | 75.5 / 21 | 83.5 / 21.9 | 3.8x | 9 / 144 | 1 / 16 (8) | yes |
| chain-20 | floating | 20 | 1 (1) | 70.5 / 26.8 | 252 / 34.5 | 247 / 35.2 | 7.0x | 20 / 304 | 1 / 0 (19) | yes |
| chain-20 | fixed | 19 | 1 (0) | 66.5 / 28.4 | 222 / 38.3 | 219 / 38.6 | 5.7x | 19 / 304 | 1 / 16 (18) | yes |
| chain-50 | floating | 50 | 1 (1) | 240 / 71.5 | 932 / 77 | 942 / 73.2 | 12.9x | 50 / 784 | 1 / 0 (49) | yes |
| chain-50 | fixed | 49 | 1 (0) | 236 / 66.9 | 898 / 81.9 | 856 / 81.2 | 10.5x | 49 / 784 | 1 / 16 (48) | yes |
| chain-5-bolts | floating | 13 | 9 (1) | 23.2 / 22.1 | 86.6 / 51.8 | 93 / 55.2 | 1.7x | 13 / 144 | 9 / 80 (4) | no (members 9 > 8, rows 80 > 64) |
| chain-5-bolts | fixed | 10 | 7 (0) | 20.1 / 18.1 | 79.3 / 59 | 80.2 / 64.3 | 1.2x | 10 / 124 | 7 / 76 (3) | no (rows 76 > 64) |
| chain-10-bolts | floating | 28 | 19 (1) | 67.4 / 46.6 | 233 / 145 | 256 / 137 | 1.9x | 28 / 324 | 19 / 180 (9) | no (members 19 > 8, rows 180 > 64) |
| chain-10-bolts | fixed | 25 | 17 (0) | 65.5 / 47.6 | 259 / 163 | 274 / 161 | 1.7x | 25 / 304 | 17 / 176 (8) | no (members 17 > 8, rows 176 > 64) |
| frame-4 | floating | 4 | 1 (1) | 13.6 / 6.12 | 30.4 / 8.32 | 28.8 / 9.21 | 3.1x | 4 / 44 | 1 / 0 (3) | yes |
| frame-4 | fixed | 3 | 1 (0) | 8.62 / 7.42 | 20.4 / 16.7 | 26.9 / 19.2 | 1.4x | 3 / 44 | 1 / 28 (2) | yes |
| frame-10 | floating | 10 | 1 (1) | 30.7 / 18.9 | 113 / 22.3 | 116 / 21.3 | 5.4x | 10 / 164 | 1 / 0 (9) | yes |
| frame-10 | fixed | 9 | 1 (0) | 32.8 / 25.1 | 80.7 / 59.6 | 85.5 / 58.4 | 1.5x | 9 / 164 | 1 / 100 (8) | no (rows 100 > 64) |
| frame-20 | floating | 20 | 1 (1) | 100 / 60.4 | 348 / 42.6 | 303 / 43.8 | 6.9x | 20 / 364 | 1 / 0 (19) | yes |
| frame-20 | fixed | 19 | 1 (0) | 94.9 / 59.3 | 226 / 120 | 232 / 127 | 1.8x | 19 / 364 | 1 / 220 (18) | no (rows 220 > 64) |
| frame-30 | floating | 30 | 1 (1) | 158 / 71.1 | 594 / 66.5 | 537 / 68.6 | 7.8x | 30 / 564 | 1 / 0 (29) | yes |
| frame-30 | fixed | 29 | 1 (0) | 162 / 98 | 408 / 191 | 418 / 192 | 2.2x | 29 / 564 | 1 / 340 (28) | no (rows 340 > 64) |
| linkage-payload-20 | floating | 24 | 4 (1) | 71.9 / 37.2 | 231 / 62.2 | 284 / 65.8 | 4.3x | 24 / 280 | 4 / 40 (20) | yes |
| linkage-payload-20 | fixed | 23 | 3 (1) | 73.6 / 38.9 | 276 / 65.7 | 274 / 68.5 | 4.0x | 23 / 280 | 3 / 40 (20) | yes |

Within the caps after M1 (members <= 8, rows <= 64), once a client reads v8: 15 of 22 (before: 4). The 7 that still do not fit: the bolted chains (every bolt spins, so it is its own body: 7 to 19 bodies, 76 to 180
rows) and the fixed frames (the redundant mates that hold the one set to the fixed base remain: 100 to 340 rows; floating, the same
frames are one body and no rows). Rows are still the binding cap there.

Previews, before → after (solves before → after; largest solve after, in bodies):

| scene | variant | probe/auto | probe/group | redundant/auto | redundant/group | conflict/auto | conflict/group |
|---|---|---|---|---|---|---|---|
| chain-5 | floating | 19.3 → 15.8 (6→6; 1 bodies) | 71.1 → 55 (6→6; 2 bodies) | 2,010 → 77.2 (9→9; 1 bodies) | 1,999 → 46.8 (6→6; 1 bodies) | 6,545 → 1,704 (28→44; 3 bodies) | 6,315 → 1,863 (14→23; 3 bodies) |
| chain-5 | fixed | 17.5 → 16.3 (6→6; 1 bodies) | 75.2 → 61.4 (6→6; 2 bodies) | 442 → 87.5 (9→9; 1 bodies) | 435 → 69.8 (6→6; 1 bodies) | 3,777 → 1,937 (28→36; 2 bodies) | 3,597 → 1,822 (14→18; 2 bodies) |
| chain-10 | floating | 17.2 → 18.9 (6→6; 1 bodies) | 148 → 100 (6→6; 2 bodies) | 2,123 → 104 (9→9; 1 bodies) | 2,095 → 90 (6→6; 1 bodies) | 9,494 → 1,698 (28→52; 2 bodies) ≠ | 9,804 → 1,408 (14→30; 2 bodies) ≠ |
| chain-10 | fixed | 19.9 → 16.2 (6→6; 1 bodies) | 141 → 101 (6→6; 2 bodies) | 1,334 → 112 (9→9; 1 bodies) | 1,381 → 107 (6→6; 1 bodies) | 10,097 → 1,768 (28→34; 2 bodies) | 10,267 → 1,763 (14→18; 2 bodies) |
| chain-20 | floating | 16.8 → 19.1 (6→6; 1 bodies) | 485 → 182 (6→6; 2 bodies) | 8,014 → 134 (9→9; 1 bodies) | 7,920 → 167 (6→6; 1 bodies) | 32,650 → 1,779 (28→38; 2 bodies) | 31,573 → 1,708 (14→22; 2 bodies) |
| chain-20 | fixed | 17.7 → 18.7 (6→6; 1 bodies) | 749 → 189 (6→6; 2 bodies) | 5,832 → 146 (9→9; 1 bodies) | 6,237 → 177 (6→6; 1 bodies) | 38,343 → 1,915 (28→34; 2 bodies) | 37,563 → 1,774 (14→17; 2 bodies) |
| chain-50 | floating | 18.9 → 20.3 (6→6; 1 bodies) | 1,694 → 436 (6→6; 2 bodies) | 21,889 → 253 (9→9; 1 bodies) | 22,937 → 415 (6→6; 1 bodies) | 129,037 → 2,037 (28→28; 2 bodies) | 129,942 → 1,977 (14→17; 2 bodies) |
| chain-50 | fixed | 19 → 20.3 (6→6; 1 bodies) | 1,393 → 433 (6→6; 2 bodies) | 23,243 → 273 (9→9; 1 bodies) | 23,688 → 446 (6→6; 1 bodies) | 155,052 → 2,091 (28→28; 2 bodies) | 153,284 → 2,222 (14→14; 2 bodies) |
| chain-5-bolts | floating | 17.6 → 16.7 (6→6; 1 bodies) | 153 → 134 (6→6; 10 bodies) | 4,727 → 108 (9→9; 9 bodies) | 4,880 → 115 (6→6; 9 bodies) | 15,270 → 2,863 (28→28; 10 bodies) | 14,693 → 2,664 (14→14; 10 bodies) |
| chain-5-bolts | fixed | 15.8 → 17.2 (6→6; 1 bodies) | 142 → 119 (6→6; 8 bodies) | 906 → 336 (9→9; 7 bodies) | 930 → 372 (6→6; 7 bodies) | 7,742 → 2,714 (28→28; 8 bodies) | 7,589 → 2,559 (14→14; 8 bodies) |
| chain-10-bolts | floating | 18.1 → 18.4 (6→6; 1 bodies) | 414 → 347 (6→6; 20 bodies) | 12,121 → 172 (9→9; 19 bodies) | 11,966 → 235 (6→6; 19 bodies) | 33,013 → 7,952 (28→28; 20 bodies) | 33,432 → 8,247 (14→14; 20 bodies) |
| chain-10-bolts | fixed | 16.6 → 17.1 (6→6; 1 bodies) | 404 → 286 (6→6; 18 bodies) | 5,205 → 828 (9→9; 17 bodies) | 5,682 → 884 (6→6; 17 bodies) | 37,616 → 7,686 (28→28; 18 bodies) | 36,443 → 7,530 (14→14; 18 bodies) |
| frame-4 | floating | 14.6 → 15.5 (6→6; 1 bodies) | 64.2 → 49.4 (6→6; 2 bodies) | 2,247 → 258 (9→9; 1 bodies) | 1,902 → 41.2 (6→6; 1 bodies) | 14,065 → 2,142 (28→28; 2 bodies) | 13,788 → 1,767 (14→14; 2 bodies) |
| frame-4 | fixed | 14.4 → 14.9 (6→6; 1 bodies) | 59.3 → 65.9 (6→6; 2 bodies) | 2,660 → 596 (9→9; 1 bodies) | 2,415 → 344 (6→6; 1 bodies) | 13,175 → 4,321 (28→28; 2 bodies) | 12,330 → 3,875 (14→14; 2 bodies) |
| frame-10 | floating | 13.1 → 14.8 (6→6; 1 bodies) | 197 → 127 (6→6; 2 bodies) | 8,963 → 223 (9→9; 1 bodies) | 9,250 → 116 (6→6; 1 bodies) | 54,770 → 1,846 (28→58; 2 bodies) | 53,637 → 689 (14→30; 2 bodies) |
| frame-10 | fixed | 14.1 → 14.5 (6→6; 1 bodies) | 205 → 168 (6→6; 2 bodies) | 8,623 → 408 (9→9; 1 bodies) | 8,434 → 322 (6→6; 1 bodies) | 50,723 → 4,267 (28→30; 2 bodies) | 49,994 → 3,773 (14→15; 2 bodies) |
| frame-20 | floating | 15.2 → 17.4 (6→6; 1 bodies) | 528 → 258 (6→6; 2 bodies) | 27,391 → 432 (9→9; 1 bodies) | 26,798 → 244 (6→6; 1 bodies) | 148,759 → 2,305 (28→34; 2 bodies) | 148,048 → 1,372 (14→30; 2 bodies) |
| frame-20 | fixed | 17.1 → 15.4 (6→6; 1 bodies) | 527 → 352 (6→6; 2 bodies) | 23,773 → 831 (9→9; 1 bodies) | 23,850 → 756 (6→6; 1 bodies) | 134,626 → 4,125 (28→28; 1 bodies) | 133,972 → 3,194 (14→16; 1 bodies) |
| frame-30 | floating | 15.5 → 20.6 (6→6; 1 bodies) | 1,074 → 435 (6→6; 2 bodies) | 45,494 → 679 (9→9; 1 bodies) | 43,159 → 371 (6→6; 1 bodies) | 243,479 → 2,742 (28→28; 2 bodies) | 245,689 → 1,930 (14→23; 2 bodies) |
| frame-30 | fixed | 16.8 → 17 (6→6; 1 bodies) | 892 → 533 (6→6; 2 bodies) | 38,520 → 1,372 (9→9; 1 bodies) | 37,645 → 1,145 (6→6; 1 bodies) | 211,098 → 4,778 (28→28; 1 bodies) | 210,797 → 3,628 (14→16; 1 bodies) |
| linkage-payload-20 | floating | 16.4 → 26.2 (6→6; 1 bodies) | 429 → 430 (6→6; 5 bodies) | 1,308 → 186 (9→9; 4 bodies) | 1,458 → 236 (6→6; 4 bodies) | 6,287 → 4,935 (28→28; 5 bodies) | 6,115 → 4,919 (14→14; 5 bodies) |
| linkage-payload-20 | fixed | 16.6 → 19.1 (6→6; 1 bodies) | 476 → 311 (6→6; 4 bodies) | 1,114 → 170 (9→9; 3 bodies) | 1,265 → 236 (6→6; 3 bodies) | 5,735 → 5,048 (28→28; 4 bodies) | 5,232 → 4,909 (14→14; 4 bodies) |

Two preview answers changed, both in the conflict case of the floating 10-plate chain: before, the search named no conflicting mate
(its 1.5 s budget ran out after 28 / 14 solves); now 52 / 30 solves fit in it and it names 1 (`auto`) and 2 (`group`).

**What did not improve, or not enough.**
- **The 50-plate chain is one body but not "the time of a 1 to 2 member group".** A solve with a wish is 77 ms against 932 before (and
  `test_the_50_plate_chain_solves_as_one_body` reports about 13x a 2-plate chain): about 100 ms of a 160 ms profile is
  `build_group_model` resolving the geometry of all 147 mates, then the follower bookkeeping and the one-off check of the mates inside
  the set. M1 does not touch the model build; caching resolved geometry would be the next step.
- **The bolted chains improve least** (drag 1.2x to 1.9x): only the plates merge, each bolt remains a body with its own rows. The
  floating 10-plate bolted chain still takes 137 ms an anchor.
- **The fixed frames** (frame-10 to 30 fixed) are one body but keep the redundant rows to the fixed base: 1.5x to 2.2x, 58 to 192 ms an
  anchor, and over the row cap.
- **Conflicts are bounded by solve count now, not by the 1.5 s budget**: 0.7 to 8.2 s (was 3.6 s to 4 minutes). The branch search
  itself stays near its budget, but the alternatives, the conflict step and a cheap solve per trial still add up: the bolted chains (2.6
  to 8.2 s) and the linkage (4.9 to 5 s, was 5.2 to 6.3: its crank, coupler and rocker stay bodies, and failing trials still run the
  full Gauss-Newton budget on them) are the slowest. Redundant previews are 41 ms to 1.4 s (were 0.4 to 45 s).
- `probe/auto` (13 to 26 ms) does not change: it only ever solved one part.

**Not verified.** Only the Python reference model and the backend were run. Nothing ran in Dart or GDScript, and nothing on a
headset: "fits the caps" is the Python model's count against the declared caps, and it applies only once M2 reads v8. One run per
side, no confidence interval. Pattern-copy sources are checked to stay out of sets, but no scene has a set next to a followed copy;
couplers are excluded by the same rule as limits but only a limit is in the tests. The gears-marked tests were not run.

### M1.1. Group solve follow-ups (CAD backend; medium; strongest agent, solver maths)

Added 2026-11-13 from the M1 results ("What did not improve, or not enough"): the gaps M1 left that no later phase covers. Backend
only, so it can run beside M2 (client only); doing it first makes M2's cap measurements better. Judge it with the same M0 benchmark,
`before` on `main` and `after` on the branch, on one machine and pinned to the same cores, as M1 did.

- **Cache resolved mate geometry.** `build_group_model` resolves every mate's geometry on every call: about 100 ms of the 160 ms
  the 50-plate chain still costs with a wish, and the main reason it is about 13x a 2-plate solve. Cache the resolved local
  `_Side` geometry (and the oriented, branch-resolved mates) per component state, keyed like `rigid_sets._detection_key` (mates
  with their references and branches, the target parts' feature fingerprints, fixed / suppressed state), so a drag re-anchor or a
  branch-search trial that changes nothing reuses it. Invalidation is the risk: a geometry edit, a pattern edit or a branch change
  must miss. Target: the 50-plate chain within 2 to 3x a 2-plate one; the platform replay and `table_top_frame` unchanged.
- **Drop redundant ground rows.** A set locked to the fixed parts keeps every mate that ties it to them: the fixed frames keep 100 to
  340 rows (over the 64-row client cap) and solve only 1.5 to 2.2x faster. Keep only rows that add rank to the set's lock against
  the ground (rank 6 is enough; the rest are checked once at the end, like the mates inside a set). The amber rule is unchanged:
  a near mate still locks, and the least-squares share-out between disagreeing mates must stay what it is.
- **One time budget for a whole preview.** `BRANCH_SEARCH_SECONDS` bounds only the branch search: alternatives, the conflict step
  and the minimum solves come on top, so conflict previews still take 2.6 to 8.2 s on the bolted chains and the linkage. Put the
  search, the conflict step and the alternatives under one budget for the whole `preview-mate-solve` (with the minimum solves
  kept), and report when it ran out. This matters more once M3 makes the preview move the real part. A shorter search can name
  fewer conflicting mates: say what changed on the M0 conflict cases.
- **Tests M1 lacks.** A rigid set next to a coupler (a gear pair on a locked frame) and next to a followed pattern copy (a set
  that includes the mover mated to a copy), each against the unreduced solve (`assembly_group.rigid_sets_enabled = False`).
- **Vector check tolerance.** `tools/motion_vectors/generate.py --check` compares text byte for byte, so it already fails on a
  machine whose numpy / BLAS round one unconverged case differently (seen on `main` during M1). Compare numbers with the vectors'
  own tolerance instead.

Not in M1.1: the bolted chains stay many bodies (each bolt spins: a real degree of freedom, not a rigid set); the client caps
are M2's.

### M1.1 results (2026-11-13)

Code: `assembly_group.build_group_model` (the built-model cache), `rigid_sets.reduce_model` (cached per set offsets; ground rows
pruned by `_prune_ground_rows`), `assembly_group.PreviewBudget` / `PREVIEW_SECONDS` and the stall stop in `_retract`,
`tools/motion_vectors/generate.py --check` (numbers within the file's tolerance). Tests: `tests/test_group_solve_followups.py` (11).

**What was built.**
- *Model cache.* `build_group_model` keys the built model on the Part's mates, occurrences (poses, fixed, suppressed) and component
  patterns, the features (with the sketches they read) of every Part it places, and the call's own arguments; each call gets its
  own copy of the poses, branches and limits. The rigid-set detection keys on the same Part state, and `reduce_model` keeps the
  re-expressed sides and the residual of the mates inside the sets per set offsets (to 1e-9), so a drag re-anchor rebuilds
  nothing. Tested: a repeat call hits and equals a fresh build; a mate value, branch, suppress, fix, pose or feature edit misses.
- *Ground rows.* A set locked to the fixed parts keeps a rank-6 subset of its mates to them (greedy, in mate order); the others are
  checked once with the mates inside the sets (an amber disagreement still gets the unreduced steps that share it out). Nothing is
  pruned unless those mates alone lock the set.
- *One budget per preview.* `preview-mate-solve` runs on one clock (`PREVIEW_SECONDS` = 2.5 s) shared by the branch search, the
  conflict step and the alternatives; past it each stops once it has had its minimum solves, and the answer says
  `budget_exhausted: true`. Create / edit (`POST` / `PATCH .../mates?solve=`) keep the search's own budget only.
- *Stall stop.* A retraction whose residual is above 0.1 (far beyond the near limits) and that took less than 1e-4 of its norm
  off over the last 5 steps stops: it is on a least-squares plateau. Before, a conflicting solve crawled through all 60 iterations
  five times (the re-weighted retries), about 1 to 2 s a trial on the bolted chains. This applies to every solve, not only previews.
- *Tests M1 lacked.* A set next to a gear pair and a set next to a followed pattern copy give the unreduced solve's answer.
- *Vector check.* `--check` now passes on this machine (it failed on `main` for one unconverged case, a numpy / BLAS rounding
  difference) and still fails on a 1e-6 change to a pinned number.

**Same answers.** The full backend suite passes (3042, 1 pre-existing skip; the gears-marked tests not run). The accuracy benchmark is
unchanged (all 50 rows identical). The platform module plan replays to identical poses (1e-12 mm) and the same 85 ok + 8 near mates.
Fixed frames: the same poses as the unreduced solve to 1e-9 at rest and with a wish.

**Benchmark.** As for M1: `main` (`71f2029`, M1 merged) against this branch, same machine type, both pinned to cores 0 and 1 with 2
BLAS threads. **The container restarted during the after-run**, so the after-scaling was run again on the restarted host (same CPU
model, kernel and cores). As a drift check the linkage family was run again on `main`'s code after the restart: it came out 5 to 20 %
slower than in the before-run (rest 35 → 41 ms, drag 62 → 69 ms, conflict previews 4.7 → 5.6 s). The after numbers below are
therefore if anything pessimistic; small differences (under ~20 %) are within that drift.

Scaling ("before" is now M1; client model rows at identity poses, as in M0):

| scene | variant | members | bodies (sets) | rest ms before / after | wish ms before / after | drag anchor server ms before / after | speed-up (drag) | client model before: members / rows | after: members / rows (followers) | fits the caps after |
|---|---|---|---|---|---|---|---|---|---|---|
| chain-5 | floating | 5 | 1 (1) | 6.92 / 2.43 | 9.15 / 4.78 | 10.1 / 6 | 1.7x | 1 / 0 | 1 / 0 (4) | yes |
| chain-5 | fixed | 4 | 1 (0) | 8.13 / 3.31 | 16.7 / 18.4 | 17.2 / 13.4 | 1.3x | 1 / 16 | 1 / 16 (3) | yes |
| chain-10 | floating | 10 | 1 (1) | 13.6 / 2.85 | 15.8 / 7.31 | 16.5 / 8.63 | 1.9x | 1 / 0 | 1 / 0 (9) | yes |
| chain-10 | fixed | 9 | 1 (0) | 14.4 / 5.63 | 24.2 / 16.8 | 24.5 / 16 | 1.5x | 1 / 16 | 1 / 16 (8) | yes |
| chain-20 | floating | 20 | 1 (1) | 26.5 / 3.97 | 30.3 / 6.77 | 31.9 / 7.82 | 4.1x | 1 / 0 | 1 / 0 (19) | yes |
| chain-20 | fixed | 19 | 1 (0) | 28.5 / 4.73 | 37.5 / 13.4 | 43.8 / 15.8 | 2.8x | 1 / 16 | 1 / 16 (18) | yes |
| chain-50 | floating | 50 | 1 (1) | 63.5 / 8.98 | 68.3 / 11.6 | 75.2 / 15.8 | 4.8x | 1 / 0 | 1 / 0 (49) | yes |
| chain-50 | fixed | 49 | 1 (0) | 78.3 / 11.2 | 77.3 / 18 | 102 / 30.3 | 3.4x | 1 / 16 | 1 / 16 (48) | yes |
| chain-5-bolts | floating | 13 | 9 (1) | 21.1 / 11.3 | 80.1 / 42.5 | 56.1 / 45.5 | 1.2x | 9 / 80 | 9 / 80 (4) | no (members 9 > 8, rows 80 > 64) |
| chain-5-bolts | fixed | 10 | 7 (0) | 24.3 / 10.9 | 68.6 / 61.9 | 64.4 / 57.5 | 1.1x | 7 / 76 | 7 / 76 (3) | no (rows 76 > 64) |
| chain-10-bolts | floating | 28 | 19 (1) | 61.6 / 27.8 | 164 / 150 | 155 / 119 | 1.3x | 19 / 180 | 19 / 180 (9) | no (members 19 > 8, rows 180 > 64) |
| chain-10-bolts | fixed | 25 | 17 (0) | 49.4 / 23.8 | 186 / 148 | 201 / 148 | 1.4x | 17 / 176 | 17 / 176 (8) | no (members 17 > 8, rows 176 > 64) |
| frame-4 | floating | 4 | 1 (1) | 8.09 / 1.53 | 10.7 / 3.91 | 8.59 / 4.34 | 2.0x | 1 / 0 | 1 / 0 (3) | yes |
| frame-4 | fixed | 3 | 1 (0) | 8.11 / 2.74 | 17.5 / 8.64 | 17.6 / 8.82 | 2.0x | 1 / 28 | 1 / 12 (2) | yes |
| frame-10 | floating | 10 | 1 (1) | 16.7 / 3.39 | 19.2 / 8.06 | 20.5 / 8.63 | 2.4x | 1 / 0 | 1 / 0 (9) | yes |
| frame-10 | fixed | 9 | 1 (0) | 25.5 / 3.61 | 53.6 / 15.6 | 53.6 / 10.4 | 5.1x | 1 / 100 | 1 / 12 (8) | yes |
| frame-20 | floating | 20 | 1 (1) | 36 / 4.51 | 41.4 / 7.22 | 40.1 / 7.3 | 5.5x | 1 / 0 | 1 / 0 (19) | yes |
| frame-20 | fixed | 19 | 1 (0) | 52.4 / 6.07 | 106 / 13.8 | 112 / 15.4 | 7.3x | 1 / 220 | 1 / 12 (18) | yes |
| frame-30 | floating | 30 | 1 (1) | 64 / 4.97 | 60.5 / 8.88 | 63.8 / 10.7 | 5.9x | 1 / 0 | 1 / 0 (29) | yes |
| frame-30 | fixed | 29 | 1 (0) | 129 / 5.77 | 308 / 13.2 | 301 / 18.4 | 16.4x | 1 / 340 | 1 / 12 (28) | yes |
| linkage-payload-20 | floating | 24 | 4 (1) | 35.1 / 9.79 | 60.7 / 32.7 | 61.6 / 38.5 | 1.6x | 4 / 40 | 4 / 40 (20) | yes |
| linkage-payload-20 | fixed | 23 | 3 (1) | 34.7 / 9.66 | 57.9 / 39.7 | 58.7 / 37.5 | 1.6x | 3 / 40 | 3 / 40 (20) | yes |

Within the caps (members <= 8, rows <= 64) once a client reads v8: **18 of 22** (M1: 15; M0: 4). The fixed frames now fit (12 rows,
was 44 to 340). The four that do not are the bolted chains (7 to 19 bodies, 76 to 180 rows: each bolt spins, a real degree of freedom).

Previews, before → after (solves; largest solve after, in bodies):

| scene | variant | probe/auto | probe/group | redundant/auto | redundant/group | conflict/auto | conflict/group |
|---|---|---|---|---|---|---|---|
| chain-5 | floating | 18.4 → 17.1 (6→6; 1 bodies) | 56.6 → 30.7 (6→6; 2 bodies) | 90.1 → 50.8 (9→9; 1 bodies) | 51.7 → 21.1 (6→6; 1 bodies) | 1,745 → 1,831 (44→46; 3 bodies) | 1,825 → 1,720 (23→25; 3 bodies) |
| chain-5 | fixed | 18.9 → 22.1 (6→6; 1 bodies) | 61.1 → 30.9 (6→6; 2 bodies) | 83.7 → 83 (9→9; 1 bodies) | 69.3 → 29.8 (6→6; 1 bodies) | 1,766 → 1,732 (36→44; 2 bodies) | 1,804 → 1,536 (18→30; 2 bodies) |
| chain-10 | floating | 19.2 → 25.2 (6→6; 1 bodies) | 96.1 → 32.1 (6→6; 2 bodies) | 93.9 → 71.5 (9→9; 1 bodies) | 99.2 → 25.4 (6→6; 1 bodies) | 1,673 → 1,714 (52→52; 2 bodies) | 1,373 → 995 (30→30; 2 bodies) |
| chain-10 | fixed | 18 → 18 (6→6; 1 bodies) | 102 → 33 (6→6; 2 bodies) | 104 → 61.6 (9→9; 1 bodies) | 104 → 29 (6→6; 1 bodies) | 1,754 → 1,863 (34→40; 2 bodies) | 1,802 → 1,546 (18→27; 2 bodies) |
| chain-20 | floating | 21.7 → 25.1 (6→6; 1 bodies) | 189 → 47.3 (6→6; 2 bodies) | 157 → 67.9 (9→9; 1 bodies) | 188 → 34.9 (6→6; 1 bodies) | 1,757 → 1,839 (36→48; 2 bodies) | 1,709 → 1,005 (22→30; 2 bodies) ≠ |
| chain-20 | fixed | 22.9 → 18.5 (6→6; 1 bodies) | 190 → 46.5 (6→6; 2 bodies) | 159 → 66.7 (9→9; 1 bodies) | 174 → 36.7 (6→6; 1 bodies) | 2,035 → 1,919 (34→38; 2 bodies) | 1,949 → 1,577 (17→24; 2 bodies) |
| chain-50 | floating | 23.6 → 25.3 (6→6; 1 bodies) | 428 → 71.2 (6→6; 2 bodies) | 276 → 82.7 (9→9; 1 bodies) | 431 → 60.4 (6→6; 1 bodies) | 2,107 → 2,044 (28→30; 2 bodies) | 1,936 → 1,154 (17→26; 2 bodies) ≠ |
| chain-50 | fixed | 21.1 → 24.1 (6→6; 1 bodies) | 437 → 72.2 (6→6; 2 bodies) | 272 → 87.4 (9→9; 1 bodies) | 416 → 66.3 (6→6; 1 bodies) | 2,265 → 1,983 (28→28; 2 bodies) | 2,164 → 1,604 (14→22; 2 bodies) |
| chain-5-bolts | floating | 17.3 → 16.6 (6→6; 1 bodies) | 139 → 70.2 (6→6; 10 bodies) | 112 → 66.1 (9→9; 9 bodies) | 120 → 47.7 (6→6; 9 bodies) | 2,956 → 2,473 (28→22; 10 bodies) | 3,045 → 1,995 (14→14; 10 bodies) |
| chain-5-bolts | fixed | 16.8 → 15.6 (6→6; 1 bodies) | 121 → 64 (6→6; 8 bodies) | 391 → 63.7 (9→9; 7 bodies) | 361 → 42.9 (6→6; 7 bodies) | 3,523 → 1,723 (28→28; 8 bodies) | 2,890 → 1,908 (14→15; 8 bodies) |
| chain-10-bolts | floating | 17.7 → 17.1 (6→6; 1 bodies) | 371 → 215 (6→6; 20 bodies) | 189 → 104 (9→9; 19 bodies) | 267 → 102 (6→6; 19 bodies) | 9,111 → 3,728 (28→22; 20 bodies) | 9,212 → 3,740 (14→11; 20 bodies) |
| chain-10-bolts | fixed | 18.9 → 19.4 (6→6; 1 bodies) | 308 → 157 (6→6; 18 bodies) | 909 → 93.7 (9→9; 17 bodies) | 1,013 → 92.6 (6→6; 17 bodies) | 8,610 → 4,053 (28→22; 18 bodies) | 8,333 → 4,220 (14→11; 18 bodies) |
| frame-4 | floating | 15.8 → 15.7 (6→6; 1 bodies) | 49.5 → 30.5 (6→6; 2 bodies) | 262 → 299 (9→9; 1 bodies) | 45 → 14.6 (6→6; 1 bodies) | 2,217 → 2,198 (28→30; 2 bodies) | 1,668 → 2,003 (14→18; 2 bodies) |
| frame-4 | fixed | 18.8 → 18.5 (6→6; 1 bodies) | 60.9 → 28.8 (6→6; 2 bodies) | 575 → 280 (9→9; 1 bodies) | 355 → 20.8 (6→6; 1 bodies) | 4,038 → 2,093 (28→34; 2 bodies) | 3,518 → 1,612 (14→17; 2 bodies) |
| frame-10 | floating | 16.7 → 23 (6→6; 1 bodies) | 122 → 28.4 (6→6; 2 bodies) | 211 → 150 (9→9; 1 bodies) | 117 → 22 (6→6; 1 bodies) | 1,821 → 1,930 (58→52; 2 bodies) | 640 → 205 (30→30; 2 bodies) |
| frame-10 | fixed | 16.2 → 14.5 (6→6; 1 bodies) | 168 → 33.4 (6→6; 2 bodies) | 392 → 160 (9→9; 1 bodies) | 301 → 38.1 (6→6; 1 bodies) | 3,758 → 2,016 (30→42; 2 bodies) | 3,452 → 295 (15→30; 2 bodies) |
| frame-20 | floating | 17 → 26.8 (6→6; 1 bodies) | 244 → 38.6 (6→6; 2 bodies) | 403 → 261 (9→9; 1 bodies) | 228 → 50.4 (6→6; 1 bodies) | 2,235 → 2,188 (34→32; 2 bodies) | 1,261 → 251 (30→30; 2 bodies) |
| frame-20 | fixed | 16.2 → 20.3 (6→6; 1 bodies) | 362 → 57.1 (6→6; 2 bodies) | 766 → 302 (9→9; 1 bodies) | 677 → 40.3 (6→6; 1 bodies) | 4,169 → 2,288 (28→30; 2 bodies) | 3,055 → 320 (17→30; 2 bodies) |
| frame-30 | floating | 18.9 → 28.7 (6→6; 1 bodies) | 367 → 51.3 (6→6; 2 bodies) | 615 → 426 (9→9; 1 bodies) | 375 → 48.3 (6→6; 1 bodies) | 2,718 → 2,480 (28→24; 2 bodies) | 2,037 → 312 (26→30; 2 bodies) |
| frame-30 | fixed | 16.8 → 23 (6→6; 1 bodies) | 499 → 72.8 (6→6; 2 bodies) | 1,200 → 440 (9→9; 1 bodies) | 982 → 54 (6→6; 1 bodies) | 4,273 → 2,481 (28→24; 2 bodies) | 3,909 → 388 (17→30; 2 bodies) |
| linkage-payload-20 | floating | 20.8 → 21.1 (6→6; 1 bodies) | 218 → 67.9 (6→6; 5 bodies) | 162 → 82.3 (9→9; 4 bodies) | 215 → 56.1 (6→6; 4 bodies) | 4,659 → 3,385 (28→22; 5 bodies) | 4,487 → 3,154 (14→11; 5 bodies) |
| linkage-payload-20 | fixed | 19 → 25.1 (6→6; 1 bodies) | 226 → 67.2 (6→6; 4 bodies) | 163 → 84.6 (9→9; 3 bodies) | 217 → 66.1 (6→6; 3 bodies) | 4,388 → 1,724 (28→28; 4 bodies) | 4,190 → 1,649 (14→14; 4 bodies) |

**What did not improve, or not enough.**
- **The preview budget does not bound a conflict preview to 2.5 s.** Each step keeps its minimum solves (8 for the search), and the
  conflict previews still take 0.2 to 4.2 s (bolted chains 1.7 to 4.2 s, linkage 1.6 to 3.4 s; were 0.6 to 9.2 s). Lowering
  `BRANCH_SEARCH_MIN_SOLVES` would bound it further but was put there for cold servers and slow CI runners; not changed.
- **Two conflict answers changed** (floating 20- and 50-plate chains, `group`): more trials now fit, and the answer names 2 conflicting
  mates where it named none. Same kind of change as M1's on the 10-plate chain.
- **The bolted chains** are still over the caps and improve least (drag 1.1x to 1.4x): the bolts are separate bodies by nature.
- **`probe/auto`** (one part moved) does not get faster, and a few rows are slower (frames: 17 → 27 ms): each distinct preview is a
  model-cache miss, and building the cache key (the mates, occurrences and feature fingerprints read as text) costs a few ms on top
  of the build. The drift above may account for part of it; not measured separately.
- `chain-5` fixed with a wish (16.7 → 18.4 ms) and `frame-4` floating redundant/auto (262 → 299 ms) are within the drift.

**Not verified.** Only the Python reference model and the backend ran: nothing in Dart, GDScript or on a headset. One run per side,
on a host that restarted between them (see the drift check). The model-cache key covers what `build_group_model` reads today; a
future input to the build that is not in the key (a new document-level setting read during geometry resolution) would need adding.

### M2. Client mirrors (Flutter and VR; medium; standard agent with the vectors as the guard)

- `local_retraction.dart` and `local_retraction.gd` read v8; followers of a set are posed from the lead member each frame
  (same shape as the v7 pattern followers).
- With sets, re-measure the caps: raise `kLocalMaxMembers` / `kLocalMaxRows` if the M0 scenes allow.
- VR: re-run `docs/local-retraction-benchmark.md` on the reduced models. If a typical group is now 1 to 3 bodies the
  GDScript solve may fit a frame; if not, VR stays on the projector (no change in behaviour). **Needs the owner on a
  Quest** for the final number.
- `preview-mate-solve`'s `budget_exhausted` (M1.1): when true the preview ran out of its time budget and `alternatives`,
  `branch_changes`, `blocked_by` or `conflicting` may be incomplete. Both mate panels parse it and say so (e.g. "Search
  stopped early: there may be more solutions"), never as an error; an older backend omits it (read as false).

### M2 results (2026-11-13)

Code (CAD repo): `client/lib/motion/local_retraction.dart` (`LocalRetractor.tryParse` reads version 8; the set metric; `followerIds`, `expandFollowers`; `LocalFrameResult.followers` / `localFollowers`), `client/lib/motion/constrained_drag_session.dart` (maps the model's leads and followers onto the anchor's member list), `client/lib/api/document_api_client.dart` and `client/lib/viewport3d/mate_panel.dart` (`budget_exhausted`). VR repo (separate PR): `scripts/motion/local_retraction.gd`, `scripts/mates_tool.gd` (limit stop on v8, `budget_exhausted`), the benchmark. Tests: `client/test/local_retraction_test.dart` (the four `local-rigid-*` vectors with their followers, "version 8 (rigid sets)" group), `constrained_drag_local_rigid_test.dart`, `local_retraction_m0_bench_test.dart`, `mate_panel_test.dart`, `document_api_client_test.dart`; VR `tests/local_retraction.gd`, `limit_mates_v8.gd`, `mates_preview_note.gd`.

**What was built, and where it differs from the M2 bullets above.**
- *Version 8 in both clients.* The members are the sets' leads; `rigid_sets` gives each lead's followers. A lead with followers uses the set metric (`M = diag(s_L²) + Σ Ad(d)ᵀ diag(s_m²) Ad(d)`, upper Cholesky `F`, `A = J F⁻¹`, `dx = F⁻¹ y`, `y0 = F⁻ᵀ(…)` with the followers wishing to stay at the lead's pose at the start of the retraction times their offset, also across the limit rounds); a lead without followers keeps the old diagonal path (a test pins a version-8 twin of a version-3 model to identical bits). Followers are posed from their leads after each frame (`expandFollowers`). Versions 3 to 7 are untouched. Malformed v8 is refused: `rigid_sets` outside version 8 (also in a version-7 model), a lead index out of range or listed twice, a follower with no id, an id that is also a lead or repeated, a bad offset, a set with no follower.
- *All 4 `local-rigid-*` vectors and every other `local_retract` vector pass in Dart and GDScript* (leads, followers and `local_followers` to 1e-9 where the vector pins them, i.e. where the raw answer is tightly converged).
- *The session.* The anchor lists every member while the model lists leads, so `ConstrainedDragSession` maps leads and followers onto the anchor's list by id (a model whose leads and followers are not exactly the anchor's members is not used and the session projects), runs the frame on the leads, and draws every member (leads from the answer, followers expanded). Before this the Flutter drag of a group with a set was projected only (M1 consequence, chain-5 / frame-4).
- *The GDScript metric is a closed form.* A follower's weight row is `[f, f, f, g, g, g]`, so `M` and the followers' share of `y0` need only `Σd`, `Σ d dᵀ`, `Σ|d|²` over the followers (`projector-spec.md` §4b, "Clients"). The first, literal port (36-element `Ad` products per follower) cost 1.9 ms for a one-lead chain with no rows; the closed form 0.43 ms. Same matrix: the vectors still pass to 1e-9 (worst 5e-11).
- *`budget_exhausted`.* `MateSolvePreviewDto.budgetExhausted` (absent = false); `mateBranchNotice(..., budgetExhausted:)` adds "Search stopped early: there may be more solutions." after the sentence the preview already has (or alone); the new-mate panel and the edit-mate dialog both call it, and the existing notice line (normal text colour) shows it. The VR status line adds it the same way. A widget test shows it in the panel; a DTO test reads true, false and absent; the GDScript test covers a ghost, a conflict, no placement, a refused request and clearing the picks.
- *Backend tooling only (no behaviour):* `tests/bench_mates_m0.py` now counts v8 as read by the clients (`_SHIPPED_CLIENT_MAX_VERSION = 8`; its M1 test asserted the opposite) and `tests/export_m0_reduced_models.py` writes `client/test/data/m0_reduced_models.json`, the 22 reduced models the benchmarks read. Run: `tests/test_mates_m0_scenes.py` 13 passed.

**Caps: not raised.** Dart one frame on the reduced models of the 22 M0 scene variants (`flutter test test/local_retraction_m0_bench_test.dart`: the JIT in debug mode on an Intel Xeon @ 2.10 GHz, 4 cores; 3 to 4 iterations + polish, wish 5 mm and 5 degrees, lever 100 mm). Microseconds per frame, floating / fixed:

| scene | leads (followers) | rows | floating | fixed | inside 8 / 64 |
|---|---|---|---|---|---|
| chain-5 / 10 / 20 / 50 | 1 (4 / 9 / 19 / 49 floating) | 0 floating, 16 fixed | 60 / 68 / 155 / 367 | 152 / 234 / 219 / 574 | yes |
| frame-4 / 10 / 20 / 30 | 1 | 0 floating, 12 fixed | 35 / 91 / 164 / 207 | 95 / 155 / 220 / 288 | yes |
| linkage-payload-20 | 4 floating, 3 fixed | 40 | 741 | 700 | yes |
| chain-5-bolts | 9 floating, 7 fixed | 80 / 76 | 5,508 | 3,190 | no |
| chain-10-bolts | 19 floating, 17 fixed | 180 / 176 | 30,801 | 34,019 | no |

The Dart count inside the caps is 18 of 22, as M1.1 measured with the Python model. The same models run through `dart run` (JIT, no asserts) and as a `dart compile exe` binary gave about the same figures (bolted chain-5 3.4 to 6.9 ms; chain-10-bolts 37 to 88 ms; the binary was no faster than the JIT on these loops, so "a release build is several times faster" cannot be assumed), run to run noise 30 % or more. Reading: everything inside the caps costs up to 0.75 ms (2 ms in the noisiest run); the cheapest bolted chain costs 3 to 7 ms, about 3 to 10 times the dearest scene inside the caps, and the 10-plate bolted chain 31 to 88 ms. A frame is 16 ms and a phone is several times slower than this desktop, and no flat-app device was measured, so `kLocalMaxMembers` = 8 and `kLocalMaxRows` = 64 stay (the constants' comment says why). What the data would allow if the owner accepts 3 to 7 ms a frame on desktop: 9 / 80 admits chain-5-bolts and nothing else; there is nothing measured between 80 and 176 rows. GDScript `MAX_MEMBERS` 3 / `MAX_ROWS` 64 stay too: the solve is not run per frame in VR, so they gate nothing today, and the desktop numbers below are above what the Quest could take.

**VR desktop part of `docs/local-retraction-benchmark.md`** (Godot 4.7.2 headless, same machine, 1000 calls per case, mean / p95, microseconds): k=1 bolt 1,051 / 1,532; k=3 row 2,856 / 4,160 (the October rows, unchanged); reduced v8 models: chain-10 floating (1 lead, 9 followers, 0 rows) **430 / 648**; chain-10 fixed (16 rows) 2,219 / 3,223; frame-10 fixed (12 rows) 1,718 / 2,463; linkage fixed (3 leads, 40 rows) 11,183 / 16,141; linkage floating (4 leads) 14,772 / 21,616; chain-5-bolts fixed (7 leads, 76 rows) 68,083 / 99,407; the projector's frame 122 / 193. In October the Quest ran this solver about 2.5 times slower than the desktop (and measured 3.1 ms p95 for k=1, a no-go), so only the rows-free case (about 1.6 ms p95 if the ratio holds, an extrapolation) is anywhere near the 1.5 ms rule. A typical group is now one lead, but "typical" there means no rows (a floating group) or 12 to 16 rows (a group held to the ground): the second costs 2.4 to 3.2 ms p95 on the desktop already.

**Live check against a real backend (Dart).** The 24-part linkage scene (4 leads, 20 followers, 40 rows) served by the backend from this branch, `constrained_drag_live_test.dart`, hand paths `flat_x` and `flat_spin`: the session ran locally on 60 of 60 frames, 0 fallbacks, residual at most 5.5e-14, no hold, no rejected anchor, and the stored poses after the commit are a fixed point of the mates (those assertions pass). The test's request-budget assertion (at most 11 requests) fails, on `main` as well: 17 requests on `main` (projector only), 18 and 19 here (`distance` re-anchors from `quality.max_step`: the F2 effect on a spin, not touched by M2). One scene, one machine.

**What still needs the Quest (and the owner).** Whether the GDScript solve may run per frame, and for which groups: run `scenes/bench_local_retraction.tscn` as described in the VR repo's `docs/local-retraction-benchmark.md` ("M2: the reduced models, what to run"); the rule there is unchanged (p95 at most 1.5 ms and max at most 4 ms per case). Nothing in VR enables the solve; only the limit stop reads the model. Also on the headset: how the limit stop feels now that it works for a group with a set.

**Not verified.** Nothing ran on a headset and nothing on a phone, tablet or a flat-app device: all timings are one desktop (an Intel Xeon @ 2.1 GHz), one run each for the table, noisy by 30 % or more. The Dart session was driven by a fake backend (3 tests) and by the live check above (one scene, a debug JIT); no widget test drives a drag of a group with a set through `PartScreen`, and no one looked at the app. The `budget_exhausted` note was tested as text and in the panel widget, never against a preview that really ran out of budget. The closed-form GDScript metric is pinned by 4 vectors and the 22 reduced models converging, not by a randomised comparison with the literal product. The caps decision is a judgement on desktop numbers.

### M3. Glide preview (Flutter and VR; medium; standard agent, UI)

No backend change: `preview-mate-solve` already returns every moved member.
- The real nodes animate (about 0.25 s, ease in-out) from the stored pose to the preview's `members` poses. A thin
  outline stays at the start pose. A new preview (type, value, Flip, Next solution) glides from the shown pose to the new one.
- Cancel glides back. Confirm stores (the atomic `POST /mates?solve=`) and the nodes are already there, so nothing jumps.
- The preview is always solved from the stored poses, never the displayed ones (the backend state does not change until
  Confirm), so picks stay valid.
- Couplers and limits place nothing: no glide.
- Flutter: replaces `matePreviewGhosts` in `part_viewport.dart`; a Controls setting "Mate preview: Move part / Ghost" keeps
  the ghost for phones where the moved part hides the picks. VR: `_run_preview` in `mates_tool.gd`; the Relax sandbox's
  `return_glide_s` tween is the pattern. **VR also gets the preview when editing a mate** (today: none).

Tests: widget / headless tests for start, replace, cancel and confirm; a failed preview leaves the part at its start.
Feel is not testable; the owner judges the glide time on the headset.

### M3 results (2026-11-13)

Flutter: `viewport3d/mate_preview_glide.dart` (the model: where each previewed occurrence is at a time; 0.25 s, cubic ease in-out; retarget / cancel / commit / outline), `PartScreen` (a `Ticker` drives it; the glide poses are drawn through the same instance override the constrained drag uses; the ghost that remains is the outline at the stored pose; `_confirmMate` and the Edit mate dialog commit the glide so the part stays put until the refreshed poses are in, and a refused confirm glides it back), and the Controls setting "Mate preview: move the part" (`ControlsPreferences.matePreviewGlide`, default on; off = the old translucent copy). VR: `mates_tool.gd` (the same behaviour on the real node: outline at the start, Clear / a changed pick / a failed preview glide back, Create keeps the part there and PATCHes the STORED pose), and **the edit-mate preview VR did not have**: Flip / Lock rotation / Value on a placing mate preview first (`preview-mate-solve` with `replace_mate_id`), with an Apply change / Cancel row on the Mates page.

Tests: `mate_preview_glide_test.dart` (7: the model and the setting), `part_screen_test.dart` (5 `M3:` tests through the real screen with a fake backend: the part itself moves and the outline sits at the stored pose, a preview stores nothing, Cancel glides home, Confirm keeps the part at the solved pose with nothing jumping and the backend storing it, a refused Confirm leaves the preview to Cancel, the setting off keeps the copy, a non-converging preview moves nothing); VR `tests/mate_glide.gd`.

What the plan says that was not done or differs: (1) the **Edit mate dialog in Flutter** glides through the same code (it already previewed with `replace_mate_id`) but no test drives that dialog; (2) the outline is the translucent ghost at the stored pose (the viewport's existing ghost), not a thin line drawing; (3) VR has no Settings switch for the old see-through copy (`MatesTool.preview_glide` exists, the flat app's setting is in Controls); (4) in a VR sandbox (relaxed) or with a grounded driven part the mate is stored, not solved, so the preview goes back instead of staying.

**Needs the owner:** the glide time (0.25 s) and ease, how the outline reads, whether the part hiding the picks is a problem on a phone, and whether Apply / Cancel is the right step for a VR edit. Not verified: nothing was looked at on a screen or a headset.

### M4. A better first guess (backend + both clients; medium; strongest agent for the rules, bench as the judge)

- **Type from the picks.** `preview-mate-solve` accepts `type: "auto"` and returns `suggested_type` with the solve: two
  round faces or circular edges, Concentric; two flat faces, Coincident; flat face and round face, none yet (Tangent is not
  a mate type); a circular edge on each side, Concentric plus Coincident offered as one action ("peg in hole", SolidWorks'
  SmartMate). Clients start on the suggestion and the user can still change it. Put the rule in the backend so the two
  clients cannot drift.
- **Pick points.** Clients send where on each face the pick landed (`pick_points`, local to each occurrence) and, flat app
  only, the view direction. Used only as a tie-break for a Closest branch: for a same-facing distance choose the side that
  brings the two pick points nearer; for alignment prefer the root that turns the picked face towards the other part.
  Must show a net gain on the M0 bench with zero harmed cases, or it does not ship (the Phase 4 rule's standard).
- Target: 83% to 90% or better overall; same-facing distance 54% to 75% or better.

### M4 results (2026-11-13)

**In one line:** the type rule shipped (backend + both clients, with Peg in hole as one action); **no pick-point rule shipped**, because every
rule I could state in words harmed at least one scene and start-class row. The targets (overall 90 %, same-facing 75 %) are **not met**: every
row of the M0 benchmark is exactly where it was. Everything below is the benchmark's synthetic scenes; nothing was run on a device or a
headset, and none of it says the first guess is better in real use.

**Step 0, the baseline on `main` (`22643c4`, M0 to M3 and M5 merged).** `CAD_API_KEY=test-api-key python -m tests.bench_mates_m0 accuracy
--trials 60 --json ...`, pinned to 2 cores with 2 BLAS threads (as M1 / M1.1). Machine: Intel Xeon @ 2.30GHz, 4 cores, Linux 6.18.44; Python
3.11.18, numpy 2.4.6, OCCT 8.0.1.2 (not M0's machine: M0's was 2.10GHz). **All 50 scene x start-class rows are identical to M0's** (right first
time, extra clicks, no way to the truth, not converged); only the preview times differ (another machine). No row moved since M0, and I think
that is expected: M1 and M1.1 changed how a group is solved (rigid sets, the geometry cache, one preview clock), not which root Closest
chooses. Every accuracy scene is one free part mated to a fixed base, so the reduced model is the full one, the branch is still resolved from
the same start pose, and the alternatives are the same; M1 and M1.1 had each already reported the 50 rows unchanged. M2, M3 and M5 are
client work. So M4 was judged against M0's numbers as they stand.

**The benchmark, extended first** (`tests/bench_mates_m0.py`, `tests/mate_first_guess_scenes.py`). The scenes the M0 plan listed (same-facing
inset and overhang with realistic pick points, upside-down starts) were already added by M0 (`inset-2`, `overhang-25`, the picks in
`GuessScene.picks`, the `upside_down` class); what was missing was *sending* the picks. Now every trial sends its jittered pick points as
`pick_points` (`--no-pick-points` turns that off). New: a **peg-in-hole** scene (a headed pin and a plate's bore; the pin's shoulder edge and
the bore's rim) run twice, as `peg_in_hole` (the suggestion) and as `[before M4]` (Coincident on the two edges: what both clients started on
before M4, which on two circles is a plain Concentric), and a **type table** (per scene: its type, the suggestion, whether a client starts on
the right type before and after). The summaries keep M0's population (the peg rows are listed apart), so they compare with M0's.

**Before (main) and after (this branch), every row.** Right first time per start class, 60 trials each; extra clicks per mate over near +
medium + far. The after-run sent pick points; the before-run could not (main has no such field).

| scene | near before / after | medium before / after | far before / after | upside_down before / after | extra clicks (near+medium+far) before / after |
|---|---|---|---|---|---|
| stack | 100.0% / 100.0% | 100.0% / 100.0% | 100.0% / 100.0% | 100.0% / 100.0% | 0.000 / 0.000 |
| parallel | 100.0% / 100.0% | 53.3% / 53.3% | 63.3% / 63.3% | 0.0% / 0.0% | 0.278 / 0.278 |
| pin-in-post | 100.0% / 100.0% | 56.7% / 56.7% | 80.0% / 80.0% | 0.0% / 0.0% | 0.211 / 0.211 |
| axis-distance-25 | 100.0% / 100.0% | 65.0% / 65.0% | 71.7% / 71.7% | 0.0% / 0.0% | 0.211 / 0.211 |
| inset-10 | 95.0% / 95.0% | 36.7% / 36.7% | 46.7% / 46.7% | 0.0% / 0.0% | 0.500 / 0.500 |
| overhang-3 | 55.0% / 55.0% | 23.3% / 23.3% | 38.3% / 38.3% | 0.0% / 0.0% | 0.611 / 0.611 |
| gap-6-above | 100.0% / 100.0% | 58.3% / 58.3% | 70.0% / 70.0% | 0.0% / 0.0% | 0.333 / 0.333 |
| gap-6-under | 100.0% / 100.0% | 68.3% / 68.3% | 66.7% / 66.7% | 0.0% / 0.0% | 0.333 / 0.333 |
| vertex-6-above | 100.0% / 100.0% | 100.0% / 100.0% | 100.0% / 100.0% | 100.0% / 100.0% | 0.000 / 0.000 |
| inset-2 | 70.0% / 70.0% | 38.3% / 38.3% | 45.0% / 45.0% | 0.0% / 0.0% | 0.600 / 0.600 |
| overhang-25 | 100.0% / 100.0% | 30.0% / 30.0% | 43.3% / 43.3% | 0.0% / 0.0% | 0.422 / 0.422 |
| inset-10-seated | 100.0% / 100.0% | 100.0% / 100.0% | 100.0% / 100.0% | n/a | 0.000 / 0.000 |
| overhang-3-seated | 100.0% / 100.0% | 100.0% / 100.0% | 100.0% / 100.0% | n/a | 0.000 / 0.000 |
| peg-in-hole (new), as Peg in hole | n/a / 100.0% | n/a / 100.0% | n/a / 100.0% | n/a / 100.0% | n/a / 0.000 |
| peg-in-hole (new), as Coincident on the edges (what a client sent before M4) | n/a / 0.0% | n/a / 0.0% | n/a / 0.0% | n/a / 0.0% | n/a / no way to the truth in 240 of 240 |

Headline (M0's population, unchanged by M4): Phase 4 set near + medium + far **75.9 %** (target 83 % to 90 %: not met; 83.3 % was the old
Phase 4 doc's number on scenes that could not be found, see "M0 results"); same-facing distances on a free part **51.8 %** (target 75 %: not
met); upside-down starts 18.2 %; every scene and start class 63.5 %, 0.440 extra clicks per mate.

**Rule 1, the type from the picks: shipped.** `app/document/mate_suggest.py` (the plan's table, every row tested in
`tests/test_mate_first_guess_m4.py`): two round faces or circular edges (any mix) Concentric; two flat faces (or planes) Coincident; a flat
face and a round face (or a circular edge) no suggestion; anything with a corner, a straight edge or a Width mid-plane no suggestion; a
circular edge on each side, each lying on a flat face, **Peg in hole** (two circles not on flat faces stay Concentric). `preview-mate-solve`
with `type: "auto"` answers `suggested_type` (the key only in that answer, possibly null) and, with a suggestion, exactly the preview of that
type; with none, `converged: false`. `type: "peg_in_hole"` previews Concentric on the edges plus Coincident on the two flat faces (touching,
the Coincident default) as one solve, and a create stores both mates or neither (`solve=` atomic as before; 422 `not_a_peg_in_hole`,
`auto_type_not_creatable`). The Concentric's alignment is the one that agrees with touching faces (from the same resolved geometry the
solver uses) unless the request names one, so a pin dropped upside down still seats: that is a rule of the action itself ("the faces touch"),
not a tie-break.
Measured: right type first **1 of 14 scenes before, 3 after, none harmed** (stack stays Coincident; pin-in-post now starts on Concentric:
before, Coincident on two cylinders already behaved as a Concentric, so its placement rows do not change, only the type it is called; the peg
now starts on Peg in hole). The peg scene is right first time in **100 % of every start class (0 % before)**. Said plainly: the peg scene is
built to the rule's own definition (a shoulder resting on the plate), so 100 % shows the action does what it says, not that users want it;
the other twelve scenes keep their placement rows because the benchmark sends their type explicitly (the suggestion changes the type a
client starts on, not how a given type is placed). Where the suggestion is wrong for a scene's intent (a Distance between two faces is
suggested Coincident; Parallel likewise; an axis distance is suggested Concentric), it is wrong before M4 too (Coincident), so no row is
harmed, but the user still has to change the type there.
Clients: **Flutter** (`part_screen.dart`, `mate_panel.dart`): until the user picks a type in the panel, the first preview of each new pair
of picks sends `auto`; the panel then shows the suggestion (the type list gained "Peg in hole" after Concentric, and the type field says
"Suggested from the picks: change it if it is not what you want."); no suggestion, or a backend older than M4 (422 on `auto`), previews the
type shown as before. **VR** (`mates_tool.gd`): the same, with the tool's type set from outside (tablet, wheel, a test) counting as the
user's choice until the tool is switched on again; "Peg in hole" is on the tablet and on the wheel's Type ring after Concentric (with its own icon; the ring
has eight wedges now, unjudged on the headset); the status line says the type was suggested; the tablet's type buttons now follow the tool's type.

**Rule 2, pick points as a tie-break: not shipped.** No candidate met the standard (net gain and zero harmed rows). How I looked: the
baseline's 3000 previews were replayed and every alternative (each branch combination solved from the same start) dumped with its
geometry and both pick points; each candidate then chose among the alternatives. For these scenes (one new mate, a free part, a fixed base)
that is what the rule would do in the server, without a server build per idea (`tests/m4_pick_rule_study.py`, `dump` then `evaluate`). The
failures first: on the free scenes the misses at medium / far are the alignment (the start's dot product picks it, a coin toss when the part
is tumbled), plus the side for same-facing distances; every upside-down miss is the alignment, and there the start is not a tie at all (the
part is clearly the wrong way up). Candidates, each a rule in words, numbers as right-first-time over the 50 rows (baseline 63.5 %, Phase 4
set 75.9 %) and the rows they harm:

| candidate (only for a Closest branch) | all rows | Phase 4 set | rows harmed (previews lost) |
|---|---|---|---|
| Same-facing distance: the side that brings the two pick points nearer (the plan's rule) | 63.5 % | 75.9 % | none, and no effect: for two parallel planes the two sides are mirror translations along the normal, so the pick points are exactly as far apart on both sides (a true tie, every time) |
| Same-facing distance: the side the driven pick point is on at the start (instead of the face's origin) | 63.5 % | 75.8 % | 3 (inset-10 medium -1, overhang-3 far -1, inset-2 near -2; it helps 4) |
| Alignment, when the start leaves it undecided (the two directions within 45 deg of perpendicular): the root that turns the driven picked face towards the other pick (the plan's rule, for plane-plane distances) | 65.1 % | 78.1 % | 4 (overhang-3 medium -9, far -6; overhang-25 medium -13, far -10); it helps insets (+30, +14, +24, +11) and gaps (+4, +1, +2): towards the other face is right for an inset and wrong for an overhang |
| the same within 30 deg | 64.9 % | 77.7 % | 4 (the same rows) |
| the same for Parallel and Coincident too | 64.9 % | 77.7 % | 6 (also parallel medium -5, far -1) |
| Alignment tie (45 deg): the two picked faces face each other | 62.6 % | 77.4 % | 8 (every same-facing row: the facing root is the gap reading of a same-facing pair) |
| the same, and the driven pick lies over the fixed face | 64.2 % | 77.4 % | 4 (inset-10 medium -1, overhang-3 medium -2, inset-2 medium -1, overhang-25 medium -2; it helps the gaps +17, +1, +8, +2): the closest to the standard, still not shippable |
| Always (not as a tie-break) prefer the face turned towards the other pick | 55.8 % | 75.2 % | 9 |
| Always prefer faces that face each other | 45.8 % | 70.0 % | 18 |

Why none works on this benchmark: from the picks alone (a face on each part) a same-facing distance and a facing gap look the same, so
every "facing" preference trades one for the other, and the inset / overhang choice is the user's (the Phase 4 doc found the same). I did not
tune thresholds against the rows to find a combination that happens to harm nothing. The view direction (flat app) is not in the benchmark,
so no rule could be judged on it.
**Follow-up spike: the view direction, then "a rule per kind of request" (2026-11-13, nothing shipped).** Both are in
`tests/m4_pick_rule_study.py` (`evaluate-view`, `selectors`) over the same dump.
*The view direction.* The benchmark has no camera, so each trial gets one, seeded per trial, from one of two models. `visible` is uniform
over the directions from which every picked flat face faces the camera at the start (you can only click a face you can see); it knows
nothing about the truth. `look_down` adds that the camera looks down at the table, an assumption about how people sit. Trials where no
single view sees both faces keep the shown answer (264 and 640 of 3000). Rules (plane-plane distances only):

| rule | view model | all rows (63.5 %) | Phase 4 set (75.9 %) | same-facing, free part (51.8 %) | previews helped / harmed (rows harmed) |
|---|---|---|---|---|---|
| V1: alignment tie (45 deg), the clicked face faces the camera | visible | 63.7 % | 73.1 % | 65.3 % | 104 / 99 (7) |
| V1 | look_down | 64.9 % | 75.7 % | 63.6 % | 91 / 50 (4) |
| V2: alignment tie, the clicked face faces away | visible / look_down | 60.1 / 60.7 % | 72.8 / 73.5 % | 37.9 / 39.3 % | 9 / 110 (10); 7 / 91 (9) |
| V3: same-facing distance on the camera's side of the fixed face | visible / look_down | 54.1 / 54.2 % | 73.4 / 73.5 % | 37.8 / 38.1 % | 98 / 379 (9); 94 / 373 (9) |
| V4: same-facing distance on the far side | visible / look_down | 53.7 / 53.8 % | 73.0 / 73.0 % | 35.8 / 36.4 % | 59 / 354 (9); 59 / 350 (9) |
| V5: V1, then V3 | visible / look_down | 54.6 / 55.8 % | 71.1 / 73.6 % | 52.5 / 50.8 % | 147 / 414 (13); 134 / 365 (11) |

None passes. V1 is the mirror of the pick-point rule: it lifts overhangs (overhang-3 medium +36, overhang-25 medium +41) and costs facing
gaps (gap-6-under medium -34, gap-6-above medium -25). With a camera model that does not know the answer, the view says only what the start
pose already says (which way the clicked faces pointed), so every rule moves the misses from one kind of mate to another. Whether real users'
views carry intent (looking at the gap they are closing) a synthetic bench cannot show without assuming it; logged sessions could.
*A rule per kind of request.* A selector chooses, per kind of request, one rule among all the candidates above (or none):

| selector sees | all rows | Phase 4 set | same-facing, free part | harmed rows |
|---|---|---|---|---|
| the scene itself (the idea's upper bound; no request carries it) | 79.0 % | 89.6 % | 88.1 % | 0 |
| the request: type and picked geometry kinds | 65.1 % | 78.1 % | 57.5 % | 4 (it picks one rule for every plane-plane distance: the alignment tie "towards") |
| the request plus its value | 79.0 % | 89.6 % | 88.1 % | 0, but only because these scenes happen to use different values for insets (10, 2), overhangs (3, 25) and gaps (6): overfitting, not a rule |

So the idea would nearly reach the plan's targets **if the selector knew the intent** (gap, inset or overhang), and gains nothing safe
from what a request actually carries: the requests that need opposite rules are identical. The only honest source of that intent is the
user (for example a Distance that asks "gap / inset / overhang" up front); that is one choice before the preview instead of a Flip after it,
so it saves a click only if the choice is remembered or defaulted well. Not built, and not measurable on this bench.

**What did ship for pick points:** the wire only. `MateCreate.pick_points` (one per reference, local to its occurrence, mm, null allowed) and
`view_direction` are accepted and checked (422 for a wrong shape), and **no solve reads them**: a test pins that the answer is the same with
and without them. Both clients send them (Flutter: the hit point taken into the occurrence's frame plus the view direction; VR: the laser's
hit point, local mm, no view direction), so a later rule needs only a backend change. Drop them if that is not wanted.

**An older client keeps working.** A request without `auto` / `peg_in_hole` runs exactly the pre-M4 code path, and
`tests/test_mate_first_guess_m4.py::test_legacy_previews_are_unchanged` replays 37 legacy previews (8 scenes, near and far starts, `auto`
and `group` movement, and in-progress payloads) against answers recorded on `main` before M4 (`tests/data/m4_legacy_previews.json`,
recorder `tests/m4_legacy_cases.py`): the same keys in the same order, the same strings, booleans, branches and list lengths, and numbers
to 1e-9. On the recording machine (x86-64) the bytes were identical too, but **not across machines**: the first version of the test compared
bytes and failed on CI's arm64 runner, whose solve differs in the last digits (e.g. `19.99999999999998`), so the numbers now get a tolerance.

**Tests.** The full backend suite without the gears marker: 3085 passed, 1 skipped (pre-existing); the 464 gears-marked tests were deselected and **not run** (they were not touched). `flutter test` in `client/`: all 3880 passed (50 skipped, as before). The bench edits were checked by the after-run above. Backend: `tests/test_mate_first_guess_m4.py` (43: every row of the rule table, pick kinds on real geometry, `suggested_type` on
the wire and its solve equal to the explicit type's, the no-suggestion answer, no key in a legacy answer, the legacy replay, pick points
change nothing and are validated, the peg from near / far / upside-down starts against the old Coincident, the atomic two-mate create, a
refused create leaves nothing, `auto` cannot be created). Flutter: `test/mate_first_guess_m4_test.dart` (14: DTO with / without / null
`suggested_type`, the request bodies, starting on the suggestion and changing it in the panel, the pick-point maths). VR:
`tests/mates_suggested_type.gd` (21 SMOKE lines); VR `tests/ci.sh`: 4387 SMOKE lines, 0 failures.

**Not verified, said plainly.** Nothing ran on a headset, a phone or a desktop window; the Flutter flow was tested as functions, a panel
widget and the API client, not as a whole `PartScreen` with a backend (its test fake has no preview route), and the viewport's capture of the
pick point is not exercised by a test (only the conversion it uses). The suggestion's quality on real models is unmeasured (the benchmark's
type table is 14 synthetic scenes). With no suggestion the client makes a second preview request (one more round trip) before a ghost shows.
VR's live-backend tests (`ci_e2e.sh`) were not run for M4.

### M4.1. A Distance where the parts are (backend + both clients; small)

Owner's request after M4 (SOLIDWORKS' flow: the faces are made parallel, the box shows the distance measured now, the user types the one
they want). Not a better guess: the side stays Closest (where the part is), so right-first-time does not change. What changes is the
order: a ghost before any typing, and a value box that starts on the real distance.

### M4.1 results (2026-11-13)

**Built.** `preview-mate-solve` with `type: "distance"`, no `value` and `measure_value: true` (opt-in, preview only) measures the picks at the
stored poses (`app/document/mate_measure.py`: two planes, a plane and a point, two axes, two points; mm, never negative, rounded to a
micrometre) and answers the ordinary preview at that distance with `measured_value` (the key only in such an answer; null and `converged: false`
when the picks cannot be measured). A request without the flag is unchanged (the M4 legacy replay still passes, including its
"no value" cases). **Flutter:** with no value typed for the current picks the panel asks once, shows the ghost, and fills the value box with
the measured distance ("Measured: the distance now. Type the one you want."); typing replaces it; Confirm with the measured value is allowed.
**VR:** before, a Distance with nothing typed was previewed at 0 (flush); now at the measured distance, `mate_value` starts on it (not counted
as typed), the status line and the tablet's value line say so, and the wheel's keyboard starts on it (empty until the answer is in; empty keeps
it). An older backend gets the old preview in both clients.

**Measured** (`python -m tests.bench_mates_m0 measured --trials 60`: the accuracy run's seeds and starts, every Distance scene; median travel
of the part's centre in the first ghost, typed value vs measured):
- The branch is the same as the typed preview's in **every one of the 2280 trials**, so right first time once the value is typed is exactly the
  M0 / M4 row: no change, as expected.
- The measured ghost moves the part **less** in 25 of the 38 scene x start rows (far starts: 64 -> 20 to 28 mm on the same-facing and gap
  scenes, 53 -> 26 mm for the vertex; near starts: 6 to 9 -> 0 to 3 mm for gaps and the vertex), the same in the 6 seated rows (the stored mate
  already fixes the distance), and **more** in 7: the tumbled same-facing starts (inset-10 medium 52 -> 64, upside-down 87 -> 154 mm; overhang-3
  medium 49 -> 53, upside-down 62 -> 117; inset-2 medium 52 -> 58, upside-down 62 -> 120; overhang-25 upside-down 60 -> 71). There the picked face
  starts on the far side of the part, so holding its current height while turning the part over carries the part further than going straight to
  the typed distance. So "nothing jumps" is true for a part that is roughly in place, not for one dropped the wrong way up.

**Tests.** Backend `tests/test_mate_measured_distance_m41.py` (10); Flutter `test/mate_measured_distance_m41_test.dart` (6); VR
`tests/mates_measured_distance.gd` (10 SMOKE lines). Full runs: backend without the gears marker 3094 passed, 1 skipped, **1 failed:
`test_rigid_sets.py::test_previews_answer_as_before[chain-3-conflict]`, which fails the same way on `main` when run on its own** (an empty
`conflicting` list: most likely the preview's time budget on a cold process; it passed inside the M4 full run) and is not from M4 or M4.1;
the 464 gears-marked tests not run. `flutter test`: all 3886 passed. VR `tests/ci.sh`: 4397 SMOKE lines, 0 failures.

**Not verified.** Whether seeing the ghost before typing saves anyone time or mistakes: no test can say; it needs the owner in the app and on
the headset. Nothing ran on a device or headset.

### M5. Show rigid sets (Flutter and VR; small; standard agent)

- Tree: parts in one set share a bracket and read "Moves with <lead>"; fully fixed sets read as fixed.
- Dragging any member of a floating set moves the set (falls out of M1); a short outline on the whole set at grab says why.
- VR: the same outline pulse the mate highlight uses (`highlight_mate`).

### M5 results (2026-11-13)

Flutter: `ConstraintStatusDto.rigidSet` (absent = null); the Assembly tree rows of a set carry a coloured left bracket (one colour per set) and read "Moves with <lead>" (the lead: "Moves with N other parts"); at the grab of a member (`_onComponentGizmoDragStart`) a snack says "Moves as one with A, B: the mates lock them together." VR: the Assembly Tree window shows the same note and a shared row colour; grabbing a member outlines every part of the set with the mate highlight's body pulse (`MatesTool.pulse_rigid_set`). Tests: `assembly_tree_panel_test.dart` (rigid sets group), VR `occurrence_tree_model`, `mate_highlight`.

Differences from the M5 bullets: (1) **Flutter has no 3D outline of the set at the grab**: the viewport's highlight is built from selected entities and one override, so a multi-part outline needs viewport work; the snack and the tree are what ships. (2) "Fully fixed sets read as fixed": a set locked to a fixed part has no `rigid_set` (M1 reports none), so its rows keep the existing fixed / fully constrained icon and show no set note; nothing new was built for it. (3) The bracket is a coloured left border per row, not one drawn bar across the rows: members need not be adjacent in the list.

Not verified: nothing was looked at on screen (widget tests only), nothing on a headset; the colours and the pulse are unjudged.

### Not in this plan

Tangent, path, cam and belt mates (`gears-and-motion-plan.md` §5a); flexible sub-assemblies; collision detection while
dragging.

---

## Part 2: Shared storage

### What is there

- Files are client-owned: a project folder (`client/lib/storage/*`, `ProjectRoot`), one Part per file, relative-path links
  (`Occurrence.external_ref`), a moved-file lookup by part id (`file_lookup.py` and its mirrors). VR has its own project
  folder (`scripts/project_folder.gd`) with Quest storage limits (All files access needed for files from other apps).
- The backend has no file system, no persistence and one in-memory `Document` per `X-Document-Session`
  (`backend/app/document/store.py`). `docs/assembly-scope.md` decisions #4 and #6 lock that in; this part reopens them.
- The roadmap already names the first step: a version check on write.

### Why a service beside the backend (D3)

| Option | Set-up for the user | Platform limits | Offline | Verdict |
|---|---|---|---|---|
| Storage service beside the backend | Nothing new: it rides on the server and the pairing QR code they already use | None: plain HTTPS from every client, no Android storage permission | Local cache + queue | **Chosen** |
| Cloud drives in the app | A sign-in per device per provider; awkward on a Quest | Each provider needs its own app registration and code; no shared folders on Quest | Needs the same cache anyway | Later, behind the same interface |
| Browser relay | Drives the provider's web page | Fragile, no sync | None | No |

Google Drive / OneDrive / a NAS still work on day one: the store keeps plain files in a plain folder tree, so the server's
folder can be a synced drive folder or a network mount.

### S0. Scope and spikes (small; strongest agent for the scope doc)

- `docs/shared-storage-scope.md`: supersedes assembly-scope #4 and #6 explicitly; the API below; the conflict rules.
- Decide: own container (like `browser-relay/`) or a router in the backend. **Recommended: own small container** in the same
  compose file, own key, so a long upload never competes with OCCT and the backend stays stateless.
- Spike (owner, Quest): where `user://` lives and how much space the cache may take.

### S0 results (2026-11-13)

`docs/shared-storage-scope.md`: what the store is (its own container, recommended; plain files on disk plus a hidden `.didsa-store/` with
SQLite and content-addressed versions), its API (versions per file, `If-Match` on every write: 412 for a stale single write, 428 without a
precondition, an all-or-nothing `commit` for Save All with 409 listing every clash, a change feed, a part-id index for the moved-files rule),
the three conflict choices (the copy gets a new Part id), the flat app's `RemoteStorageService` and DIDSA-VR's **mirror folder** in its own
storage (no storage layer under every file call, no *All files access*), and eight owner decisions with recommendations (section 8). It
supersedes `assembly-scope.md` #4 in part and keeps #6 for the backend; composition stays on the client.
Found while scoping: the pairing key `s` is reserved for the document session (the store uses `p` / `pk`); the flat app's Save All has
no "changed on disk meanwhile" check for local folders (VR has one; recommended for S2).
**The Quest spike** is built (DIDSA-VR Launcher > Servers > Check storage, `scripts/storage_probe.gd`, `tests/storage_probe.gd`) and run only
on a desktop; the owner's answers go in DIDSA-VR `docs/android-build.md`, "Storage for server projects".
Housekeeping in the same PR: the M4 / M4.1 rows marked done; the branch search's own clock (`BRANCH_SEARCH_SECONDS`) now sets
`budget_exhausted` when it cuts the conflict step short (it used to answer `conflicting: []` as if nothing conflicted), and
`test_rigid_sets.py::test_previews_answer_as_before` compares the two models with the clocks out of the way (it failed whenever the slower
unreduced preview ran out of time).

### S1. Project store service (CAD repo, new `project-store/`; medium; standard agent)

- `GET /projects`, `GET /projects/{id}/tree` (path, size, content hash, version, modified by, root part id).
- `GET /files/{path}` with `ETag`; `PUT /files/{path}` with `If-Match` (**a stale save is refused with 409**, the roadmap's
  first safeguard); `If-None-Match: *` for a new file; delete and rename.
- Keeps the last N versions of each file (a refused or mistaken save can be recovered).
- `GET /changes?since=<cursor>`: what changed, for sync after being offline.
- A part-id index of the tree, so the moved-files rule works against the server.
- Advertised by the backend's `/health` `api_features` and carried in the pairing code (`&p=<store>&pk=<key>`: S0 found `s` is reserved for the document session,
  `docs/vr-headset-pairing.md`), so a paired client finds it with no typing.
- No locks (the long-term vision doc rules out PDM-style locking): optimistic version check, and on conflict the user
  picks Keep mine (as a new version) / Take theirs / Save mine as a copy.

### S1 results (2026-11-13)

**Built** (`project-store/`, its README is the reference): FastAPI + stdlib `sqlite3` (WAL), one worker, one lock; its own
`PROJECT_STORE_API_KEY` and `PROJECT_STORE_ROOT` (it refuses to start without either); every endpoint of scope section 5 with the
status codes given there (412 stale single write, 428 no precondition, 409 commit listing every clash with nothing written, 413 over
200 MB); uploads for commits (valid an hour); a version counter per file with the SHA-256 alongside; kept versions by content hash in
`.didsa-store/blobs`; the change feed with a cursor; the part-id index; `X-Device-Name` recorded as "modified by". The "changed outside
the store" scan is stat-first and hashes only on a difference (size or mtime); it runs before every read of a tree, feed, index,
project list or file and before any write (a commit scans the whole project). Retention: last 20 versions and anything under 30 days,
whichever keeps more; a deleted file's versions 30 days. The part id is `document.root_part_id` read from the JSON of a native file,
nothing else. The backend's `/health` gains `project_store` (from `PROJECT_STORE_URL`, never the key) and `"project_store"` in
`api_features`, only when set. Compose gained the `project-store` service; `.github/workflows/project-store-verify.yml` runs its
tests (the relay's tests still run in no workflow). The backend is unchanged otherwise and the store imports no backend code.
Scope doc: section 8 marked accepted; section 5's `/health` row corrected (needs the key).

**Differs from the scope, and why:**
- A path ending `versions` or `versions/<digits>` is refused (it would collide with the history routes); `parts/{id}` answers 200 with
  an empty list for an unknown id; the tree and commit responses carry a `cursor` (so a client can start the feed where its tree ends).
- A move in a commit appears in the feed as a `delete` (with `moved_to`) and a `put` (with `moved_from`). A move onto an existing file
  is a clash (`target_exists`); a new file where a folder is (or the other way round) is a clash (`path_conflict`).
- A save that changes nothing makes no new version (200, `unchanged: true`).
- A version counter outlives retention: a long-deleted file keeps its delete record, so a stale copy cannot match a file re-created later.
- `PROJECT_STORE_API_KEY` is not the pairing code's `pk`: S2 / S3 add that. No `p` / `pk` here.
- Licence: `project-store/` is GPL-3.0-only like `browser-relay/` (REUSE.toml / LICENSING.md); the owner may prefer AGPL (a hosted service).

**Tests:** `project-store/tests` (pytest, TestClient, temp dir per test, injected clock, threads for the races): every endpoint,
stale PUT, whole-commit 409 (files and DB compared before and after), a failure part-way through a commit rolled back, races,
outside edits, the feed, the index after a rename, retention, every refused path. A few mutations (scan off, retention rule, conflict
check, rollback) were tried and each broke a test.

**Verification and what is not:** nothing has run on the owner's Pi, behind the Cloudflare tunnel, or with a synced Drive / NAS folder as the root
(scan and `os.replace` behaviour there is untested; a change that keeps both size and mtime is missed by design). The 100 MB tunnel
limit is documented, not measured. The image was built and its tests run inside it (206 passed, 1 skipped: the test that reads the backend's data file, which is
not in the image); a container was started with a volume and answered 401 / 200 / 201 / 412 as expected, and refused to start without a
key. The sandbox's proxy needed its CA added to pip in a scratch copy of the Dockerfile (as `browser-relay/README.md` describes); the
repo's Dockerfile is unchanged, so a build behind such a proxy needs the same. The full backend suite was run natively (conda env from
`backend/environment.yml`, `CAD_API_KEY=test-api-key`, `-m "not gears"`, `-n auto`): 3098 passed, 1 skipped. The gears-marked tests
were NOT run. Docker was built for amd64 only, not the Pi's arm64. Performance (a big first scan, a 100 MB JSON parse for a part id) and SD-card wear were not measured. No client exists yet.

### S2. Flutter (medium to large; standard agent)

- A `RemoteStorageService` behind the existing `StorageService` interface, so Open / Save / Save All / the composer are
  unchanged above it.
- Local cache of every opened file (`file_cache.dart`), a queue of unsent saves, a sync state per file (synced, to send,
  conflict) and a status chip. Offline: open from the cache, save to the queue, sync on reconnect with the version check.
- File menu: "Server projects" next to the local project folder; "Copy this project to the server".

### S2 results (2026-11-13)

**Built** (`client/` only; no store or backend change, no VR change). `docs/shared-storage-scope.md` sections 6, 7 and 9 as written, with the
differences below.

- **Storage layer:** `ServerProjectRoot` / `ServerFileHandle` beside the sealed local variants; `RemoteStorageService` and a
  `RoutingStorageService` (`lib/storage/`), which `createStorageService()` now returns (`createLocalStorageService()` is the old
  platform pick), so Open, Save, Save All, the composer, the AI screen and the relative-path dialogs reach a server project with no change
  above the interface. Two additions to `StorageService`: `writeFile(..., {int? baseVersion})` (the three local services and every test
  fake ignore it) and `supportsCommit` / `commit` (a `FileByFileCommit` mixin gives the local services the file-by-file version).
- **Store client** (`server/store_client.dart`): every store status becomes a typed error: 401, 412 (with `current`), 409 on a commit (every
  clash), 413 (told apart from a tunnel's 413 by the JSON body), 400 / 422 (the store's message shown), 428 (reported as a bug in the app,
  and the client always sends `If-Match` or `If-None-Match`, so it should never occur), 404, and an unreachable store (`StoreUnreachable`,
  which queues). `X-Device-Name` is sent on every call (non-ASCII characters replaced so the header is legal) and trusted for nothing.
- **Local copy, queue, sync state** (`server/sync_state.dart`): `FileCache` is the server project's local copy (it now also keeps the
  store's version of each file). The queue of unsent saves, each file's base version, the last file list, the feed cursor and the "mine" copies
  are in a `SyncStore` in the application-support folder, **not** the OS cache folder, because the queue holds the only copy of a save the
  store has not got and the OS may clear a cache. The chip (`ServerSyncChip`) shows Synced / N to send / Clash / Offline, and its sheet has
  Sync now, Resolve and Discard (for a save the store will not take).
- **Saves:** every save is staged in the queue first, then sent: a single file as `PUT` with the version it replaces; Save All as one
  `commit` (uploads, then one all-or-nothing request). Sent: done. Store unreachable: stays queued, "saved on this device". Stale (412 or
  409): stays queued flagged as a clash with what the store says is current, `SyncConflictException` (a `StorageException`) tells the
  caller, and nothing was written. A file whose bytes equal the version it was read at is not sent. 413 / the tunnel limit: a clear message
  (a file over 100 MB that fails while the store still answers `/health` is explained as the Cloudflare tunnel's limit; no chunking) and the
  save stays queued with a Discard button.
- **Sync** (`sync(root)`; a 20 s timer while a server project is open, plus Sync now): the change feed from the saved cursor first (an empty
  answer costs no file list), saved saves that the feed shows are now stale are flagged as clashes without sending, cached copies of files
  others changed are refreshed, then the queue goes as one commit. A cursor the store rejects falls back to comparing with the tree.
- **Conflicts** (`sync_conflict_dialog.dart`): per file, who changed it and when ("Changed by Quest 3 on ...", "Renamed to X by Phone",
  "Deleted by ...", "A file with this name was added by ..."), Keep mine / Take theirs / Save mine as a copy. Keep mine on a deleted or
  renamed file writes it at the old path again. Take theirs loads theirs (or removes the local file if theirs is a delete) and keeps my bytes
  until the next sync after the one that finishes the resolution; "Put back as a file" is in the service (`restoreKeptCopyAsFile`), not yet
  in a screen. The copy is `<name> (<device>, <date>).didsa` (a number is added if the name is taken) with a new document, Part and sketch
  id (`remintNativeIdentity`, as Save As). A commit 409 queues every change of the commit, flags the clashes and writes nothing; after the
  choices `sync` sends the commit again. After Take theirs / a copy the open session no longer matches the store, so the note offers Reopen.
- **File menu and settings:** "Server projects..." next to Open and "Copy this project to the server..." next to Save All (phone menu and
  desktop menu bar; hidden when the screen has no store service). The store's address, key and this device's name are entered once in
  the Storage screen (home screen > Storage; `ApiConfig.storeUrl`, `storeApiKey`, `deviceName`; the default name is the computer's name, else the platform). If
  `/health` carries `project_store`, that address is saved as the default when none is set (the key is never known to the backend). No
  pairing keys (S3).
- **S0-8:** Save All on a local folder compares each file's modified time with the one this session saw when it read or wrote it
  (`LocalFileStamps`, filled by the composer and by saving) and, when any is later, asks: Overwrite / Skip these files / Cancel. A file the
  session never read or wrote is not checked. Plain Save is not checked (the scope says Save All).
- **Moved-files rule against the store:** `ProjectFileIndex.build` / `partIdAt` read the file list the store already has (each file's root
  Part id is in it) instead of reading every file, and the composer first asks `GET .../parts/{part_id}` for a reference's id: when that
  gives one file or several (found / ask) no list is built at all; anything else goes on to the whole list, as for a folder. Files saved
  but not sent yet are included from their own bytes.

**Differs from the scope, and why:**
- **A single-file Save is a `PUT` (412 on a stale one), not a commit of one file**, as the build brief asked; both paths share the queue.
- **The base version** is the version of the file the first time it was read in a session (`beginSession` is called when a project is
  opened), or the version a later write made: a later re-read (Add Component, a second compose) does not move it, so a stale Part in the
  open session can never be saved over a newer version without a clash. The scope did not say this.
- **"Take theirs ... until the next successful sync"** is read as the next sync after the one that finishes the resolution (otherwise it
  would be dropped at once).
- **The copy's `<device>` is this device's name** (whoever makes the copy), not the other side's; the scope's wording was ambiguous.
- **Renaming a file in a server project is online only** (a commit `move`; offline it says so, and a file with an unsent save must be synced
  first). The scope did not mention rename.
- **A commit refused with 400 for one bad file** leaves its changes queued with the store's message in the chip's sheet, where each can be
  discarded; the store does not say which file it was, so the client cannot drop the right one by itself.
- **The change feed is used for sync, not for the file list**: it has no hashes or sizes, so a changed file list is fetched as a tree.
- **Found on the owner's first real use (13 Nov) and fixed in this PR:** File > Server projects only switched a session into a project by
  opening one of its files, so choosing a new (empty) project did nothing and later Saves went to the local folder flow (no chip, no
  request to the store). Now an empty project is adopted as the session's project (Save / Save All write there), a project with files asks
  "Save current work here" or "Open a file", and Copy to the server from a folder with no files says so and still adopts the new project.
- **The status indicator moved into the quick menu (13 Nov, owner's request: the chip covered the triad), as symbols:** cloud done /
  upload / warning / cloud off for a server project, and a folder symbol while a store is set up but the session saves locally (so
  "not syncing" is visible, not just the absence of a chip).
- **Home screen (13 Nov, owner's request, same PR):** the old connection screen is replaced by a logo-and-five-tiles home screen in three
  styles (Blueprint, Instrument panel, Drawing sheet) chosen from a settings wheel, with Server and Storage screens, status lights
  (green / red / grey), CAD tools and the VR headset greyed without a server, and the sub-menus themed to match (`client/lib/home/`,
  `client/README.md`). "Cloud storage" is the user-facing name for the project store. Not checked on a device: how the three styles look.
- The queue is not in `FileCache` itself (see above); `FileCache` only gained the version field and now creates a given directory.

**Tests:** `test/remote_storage_service_test.dart` (47: reads, versioned writes, the stale write, every store status, offline queue and
restart, sync on reconnect with the feed first, the three choices, deleted / renamed clash, Save All as one commit including a 409 that
writes nothing and the retry, an expired upload, rename, the moved-files lookup counted by requests, copy to server, settings),
`test/server_projects_widget_test.dart` (19: the store section of the settings, the project list, the conflict dialog, the changed-on-disk
dialog, the chip), PartScreen groups in `test/part_screen_test.dart` (10: the menu entries, Save All as one commit, a clash and Keep mine,
Decide later and the chip, offline then Sync now, and the S0-8 question with Skip / Overwrite / Cancel), and
`test/assembly_document_client_test.dart` (9 new: Save All as one commit through a commit-capable storage, a clash propagating, an all-or-nothing
failure, queued files reported apart, and the S0-8 check with Skip / Overwrite / Cancel / no question), and
`test/live/server_store_live_test.dart` (12, against the real store). The fake store is `test/support/fake_project_store.dart`. A few
mutations were tried (a write that always creates instead of replacing, a 409 that does not flag the clashes, a copy that keeps its Part
id, a re-read that moves the base version, the S0-8 check off, the composer's part-index shortcut off); each broke a test.
**The real-store test does fit the existing e2e conventions** (a plain `test()` in `test/live/`, skipped unless an environment variable is
set, as `moved_files_live_test.dart` is); it is run by a new workflow, `.github/workflows/client-store-e2e.yml`, which starts the store
(uvicorn, a temp root, its own key) and runs it. The older live test is not run by any workflow; this one is.

**Verification and what is not:** `flutter analyze` is clean and the full client suite passes (Flutter 3.47.9, the version
`client-verify.yml` pins; see the PR for the counts). The 12 live tests passed against `project-store` started locally from this branch
(`PROJECT_STORE_API_KEY=dev PROJECT_STORE_ROOT=/tmp/store python -m uvicorn app.main:app --port 8200`). Not verified: nothing has run
against the owner's Pi, the Cloudflare tunnel (the 100 MB behaviour is the documented limit plus a simulated cut-off connection) or a synced
Drive / NAS root; headless tests cannot judge how the conflict dialog, the chip or the sheet feel or look on a phone or a desktop, and the
widget tests drive the phone layout only for the File menu; Android SAF and iOS bookmark paths are unchanged and untested for server
projects (a server project never touches them, but the app was not run on either); the 20 s sync timer and the app being killed mid-sync
are covered by the persisted queue's design and the restart test, not by a test that kills the process; very large projects (the
queue holds every unsent file in memory while it is sent) were not measured.

### S3. VR (medium; standard agent)

- `project_folder.gd` gains a server source: Files lists server projects; the cache lives in `user://` (no All files access
  needed, which removes most of the Quest storage friction).
- Same queue and conflict rules as S2. The landing shows what is waiting to sync.

### S3 results (2026-11-14)

**Built** in DIDSA-VR (PR #85, open when this was written; nothing in `project-store/`, `backend/` or `client/` changed). The VR notes are `docs/server-projects.md` there.

- **A visible mirror folder per server project**, `Documents/DIDSA-Cloud/<server host>/<project>/`, a sibling of `Documents/DIDSA` (not nested in it: the moved-files index skips
  dot-folders and the local Files list would show a nested one). VR's `native_compose.gd`, `file_lookup.gd`, `file_index.gd` and `project_save.gd` read and write it unchanged. The
  root is one setting (`[cloud] folder=` in `settings.cfg`). It needs *All files access* like the local project folder; without it the mirror falls back to `user://DIDSA-Cloud` and the
  Files page says so.
- **The sync state is private** (`user://didsa-cloud-state/`): each file's version and hash as last synced, the queue, the feed cursor, the "mine" copies kept after Take theirs. Deleting the
  mirror cannot delete the queue; a queued save whose file is gone is warned about, never sent as a delete.
- **Local changes are found by scanning the mirror (SHA-256)**: a dropped file is a queued create (base null), an edited one a queued edit, a removed one only "not downloaded". Nothing in VR
  sends a delete.
- **S2's rules and words**: a base version is not moved by a re-read (a file the open session holds is never refreshed under it); a single save is `PUT` with `If-Match` (a create `If-None-Match: *`,
  never a write without one), Save All is one commit; 412 / 409 are per-file clashes with who and when (`X-Device-Name`) and Keep mine / Take theirs (mine kept until the next sync after the resolving
  one) / Save mine as a copy (`<name> (<device>, <date>).didsa`, a new document, Part and sketch id: VR had no remint, so `cloud_remint.gd` is a GDScript twin of `remint_identity.dart`); a deleted or
  moved file is a clash; 401 names the key, 413 / 400 show the store's message, an unreachable store queues; a file over 100 MB that fails while the store answers is reported as the tunnel's limit.
- **Sync**: the change feed from the saved cursor first, then the queue as one commit; a refused cursor falls back to the tree. On open, every 20 s while a project is open, after Save, and on Sync now.
- **The moved-files rule against the store**: `GET .../parts/{part_id}` (the tree's part ids offline) instead of reading files.
- **Screens**: wrist tablet > Files > Server projects (a state symbol per project and file), the landing's "waiting to sync" row, the Servers page's store address / key and device name. The QR code's
  `p=<store address>` and `pk=<store key>` are read.

**Differs from the scope, and why:**
- The mirror is in Documents with the state private in `user://`, not `user://projects/<server>/<project>/` with a `sync.json` beside it (section 7 of the scope): the owner wanted to drag files in by
  hand, which `user://` does not allow, and a visible folder must not hold the queue. It therefore needs All files access (the scope said it would not).
- The queue is found by scanning, not recorded at save time, so `project_save.gd` is unchanged.
- A file the store removed is removed from a clean mirror (the flat app evicts its cache copy); the store keeps the history.
- Conflict choices are buttons on the tablet list, not a dialog; after Take theirs or a copy the status line says to open the file again (no automatic reload).
- Not built: rename in a server project, "Copy this project to the server", a settings screen for the mirror root.

**What the flat app must still do (small follow-up here):** `client/lib/vr_pairing/` must write `p=<the store's address>` and `pk=<the store's key>` (percent-encoded like the other values; both optional;
left out when no store is set). The headset reads them already; a code without them still pairs.

**Tests (VR):** `cloud_paths`, `cloud_remint`, `cloud_sync`, `cloud_moved_files`, `cloud_manager`, `cloud_ui` (a fake store, `tests/fake_project_store.gd`, after `client/test/support/fake_project_store.dart`): 197 SMOKE
lines, the whole suite 4623 / 0 failures; and `e2e_cloud_store` (31 lines) against the real store from this repo's `main`, which `tests/ci_e2e.sh` starts and the e2e workflow installs the requirements for.
Four mutations (no precondition, refreshing a held file, a remint that keeps ids, a send that does not clear the queue) each broke tests.

**Found while checking CI (not S3):** the VR e2e job is red on VR `main` too, in `e2e_gear_train`, `e2e_limit` and `user_session_train` (22 lines; the same on 14 Nov before and after S3). Reproduced locally against
this repo's `main`: `mate-motion` on the gear train answers 422 `unsupported_mate_geometry` for `bevel_a`. The demo's bevel mates (added to VR's `demo/assemblies/gear_train/Gear_train.didsa` on 25 Oct)
refer to the bevel gears' faces 3 (bore) and 4 (back plane), which are `other` in the body the backend builds now; its bore cylinder is face 81 (or 105) and its back plane 104 (106 faces in all). With the bevel mates
re-pointed to 81 and 104 in a scratch copy the same request answers 200 and no mate is broken. So the demo is stale against the current bevel face numbering (what changed in the backend is not known: the history is
squashed). Not fixed here: the demo's mates need re-authoring (or the failing tests moved out of the CI list), and a mate on a bevel gear's face index is fragile whenever the generator changes. Face 81 vs 105 was
not checked against the geometry.

**Verification and what is not:** headless with a fake store, and 31 assertions against the real store over the real HTTP transport. Not verified: anything on a headset (the permission prompt, whether
Documents/DIDSA-Cloud works on Horizon OS, speed, how the screens read, the laser on the new buttons), the Quest storage check (S0) which the owner still has to read off, the owner's Pi, a Cloudflare tunnel,
a synced Drive / NAS root, killing the app mid-sync, a large project's first scan.

### S4. Hardening (small to medium)

Interrupted uploads, a server that comes back mid-save, two devices offline on the same file, large STEP imports, cache size
limit and clean-up, thumbnails for the VR Rooms and landing tiles. Tests run against a store that is switched off and on.

---

## Part 3: Live sessions, observers and the phone app

### What is there

Nothing built. The idea is in `DIDSA-VR/docs/vision-brief.md` ("Multiplayer and environments", "Phone observer").
`docs/vr-recon-2026-09-24.md` §5 lists what the backend lacks: session separate from document, a push channel, identity.
D2 (one presenter) removes the hardest of those, concurrent edits.

### Shape

```
Presenter (Quest / PCVR) ── REST ──> CAD backend (the presenter's document session, as today)
        │                                  ▲ read-only, by a session token
        └── WebSocket ──> Session hub <── WebSocket ── Observers (Quest, phone)
                          (presence, model state, marks, voice)
```

- The presenter works exactly as now. The app also publishes what changed to the hub.
- Observers fetch the same glb from the CAD backend **read-only** using a token the hub hands out, then apply the hub's
  stream: occurrence poses (20 to 30 Hz during a drag), visibility, appearance, shown scene, section planes, the model's
  place and scale, and a "geometry changed, refetch" signal after a design-table edit.
- A late joiner gets a snapshot, then the stream.
- Presence at about 15 Hz: head, hands or cursor, laser end, name, colour, role.
- Everything goes out through the same tunnel as the backend (`wss://`), so remote observers need no new network set-up.

### P0. Scope and three spikes (strongest agent for the protocol; spikes need the owner's devices)

- `docs/live-sessions-scope.md`: message list, roles, the read-only token, what is never sent (API keys, files).
- **Voice spike.** Microphone to Opus to WebSocket to playback, on a Quest and an Android phone. Godot has no Opus encoder
  reachable from GDScript, so voice uses **one more add-on exception, allowed by the owner (D9)**: a small Opus
  GDExtension, pinned and fetched by a `tools/` script like the OpenXR Vendors plugin, and noted in DIDSA-VR's `CLAUDE.md`.
  The spike picks the add-on (it must build for Quest and phone arm64 and for desktop) and checks microphone capture on
  Android in Godot 4.7, which was not verified when this plan was written; it settles both before P3 is sized.
- **Cardboard spike.** Gyroscope camera, side-by-side stereo with lens distortion, 60 fps on a mid-range phone with a real
  assembly and today's shaders.
- **`main.gd` split audit.** Which of its 2,457 lines are viewing (scene, glb, environment, clip) and which are Quest input;
  the list of what a view-only build must not load.

### P1. Session hub (CAD repo, new `session-hub/`; medium to large; strongest agent)

- Rooms with a short join code and a QR code; roles presenter / observer; display name and colour.
- Relays presence, model state, marks and voice frames; keeps the latest snapshot for late joiners; no geometry.
- Backend: a read-only token that lets another client `GET` the presenter's assembly mesh / glb and tree, and a document
  change counter so observers know when to refetch. No write route accepts the token.
- Tests: a scripted presenter and two scripted observers; late join; presenter drops and returns.

### P2. VR Host and Join (VR; large; standard agent, owner testing with two devices)

- Home monolith: **Host Session** (shows the join code and QR) and **Join Session** (type or scan). The same app; the role
  decides which tools exist. An observer has no mates, design table or save.
- Avatars (D6): a headset shape, two controller shapes with the laser, a name tag that faces the viewer, one colour each.
- Live model state from the presenter, smoothed between updates.
- Go to presenter, Follow presenter (rides their viewpoint, with a comfort vignette), and the presenter's Gather everyone.
- **Scale (decide here):** recommended v1 is one shared model place and scale set by the presenter; presence is sent in
  model space so avatars stay correct. A private scale for an observer is a later step.

### P3. Voice (hub + VR; size set by the P0 spike)

Open mic with a mute, push-to-talk option, voice placed at the speaker's avatar with a floor so far people stay audible,
per-person volume, the presenter can mute all. The hub relays frames; it does not mix.
**First usable session release = P1 + P2 + P3 (D5).**

### P4. Observer tools (VR; medium; standard agent)

- **Drone cursor.** A small coloured, named marker the observer flies through the model. It selects what it touches or
  points at, with the existing breadcrumb (Face, Body, Part, sub-assembly) to choose the level.
- **Own view (default):** colour, hide, isolate, see-through, section, measure, pull a part out (an exploded look). Uses the
  Appearance tool, section tool and Relax sandbox code paths, with nothing sent to the backend.
- **Share (D7):** shows the current selection and its colour to everyone as a temporary mark with the observer's name; the
  presenter clears marks. Also Ping (a pulse at a point), Raise hand, Look here (asks the presenter to come).
- **Reset my view** puts everything back to what the presenter shows.

### P5. Phone (Cardboard) observer (VR repo, second Android export; large; standard agent + owner's phone)

- OpenXR off; the P0 camera rig; a "magic window" mode (no viewer, the phone is a window you turn) as the fallback and for
  people who get sick.
- Bluetooth controllers through Godot's joypad input. Mapping, also on a help card in the app:

| Control | One-handed wand (stick, A, B, trigger) | Full gamepad adds |
|---|---|---|
| Move yourself | Stick (forward / back / strafe, in the direction you look) | Left stick; right stick turns in snaps |
| Drone cursor | **Hold the trigger**: the stick flies the cursor, your gaze steers it | Right stick flies it at any time; triggers raise / lower it |
| Select | A at the cursor (or at your gaze with no cursor out) | Bumpers step the breadcrumb level up / down |
| Back / menu | B: back; hold B: the tool ring | D-pad: tool ring directly |
| Quick tools | In the ring: Colour, Hide, Isolate, Share, Ping, Go to presenter, Reset | X colour, Y hide, Start mute, Select reset view |
| No controller | Gaze and dwell on a small menu: Follow presenter, Go to presenter, Mute | |

- Lighter rendering for phones (simpler materials, MSAA off, the LOD work in `docs/lod-strategy/`).

### P6 and P7 (later)

P6: the flat app joins as an observer (a 2D view with the same marks and voice), then hosts. P7: reconnects, more than six
people, per-device keys (pairing version 2 in `docs/vr-headset-pairing.md`) so one person can be removed.

---

## Order and dependencies

```
M0 → M1 → M2 ─┐
      ├→ M1.1 │ (beside M2; before M2's cap measurement if possible)
      └→ M5   ├─ mates done
M3 (any time) │
M4 (after M0) ┘
S0 → S1 → S2 ─┬→ S4
          S3 ─┘
P0 (spikes can run during S) → P1 → P2 → P3 → P4 → P5
```

- M3 and M4 do not depend on M1; they can go to a second agent while M1 is in review.
- S1 before P1 is not a hard dependency (observers get geometry from the presenter's backend session, not from files), but
  the presenter needs S2 / S3 to open the same project on every device, so storage stays second (D1).
- P0's spikes need only the owner's devices and can run while storage is being built.

## Which agent for which phase

| Kind | Phases | Why |
|---|---|---|
| Strongest model, high effort | M1, M1.1, M4 rules, S0, P0 scope, P1 | Solver maths, protocol and data-model decisions that later phases build on |
| Standard model | M0, M2, M3, M5, S1 to S4, P2, P4, P5 | Client and service work with a clear spec and golden vectors or tests as the guard |
| Needs the owner's hardware | M2 (Quest timing), M3 (glide feel), S0 spike, P0 spikes, P2, P3, P5 | Headless tests cannot judge feel, audio or frame rate |

Each phase starts with its own short kickoff prompt naming this doc, the phase id, the files listed there and the tests
that must pass, as `docs/motion/s5-s6-kickoff-prompts.md` did.
