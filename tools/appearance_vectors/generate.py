#!/usr/bin/env python3
"""Golden vectors for the Appearance tool's resolution rule (docs/appearance-tool-scope.md D3).

    python tools/appearance_vectors/generate.py            # (re)writes docs/appearance/vectors.json
    python tools/appearance_vectors/generate.py --check    # exits 1 if a committed copy differs

The reference implementation is `backend/app/document/appearance.py` (pure Python, no OCCT); this script loads that one
file by path and writes what it answers for hand-built cases. DIDSA-VR (GDScript) and the flat app (Dart) copy the rule
and are tested against `docs/appearance/vectors.json`; the backend's own copy (`backend/tests/data/appearance_vectors.json`,
the CI image holds backend/ only) pins the reference itself, so an edit to the rule without regenerating fails there.

Each case: `model` (a name in `models`), `root`, `path` (occurrence path segments from the root, `#pattern:` copies
allowed, [] = the root's own bodies), `body_id` / `face_index` (null = the instance as a whole: only whole-node targets),
optional `scene_overrides`, and `expected` (the resolved fields; unset fields are absent). `why` says what it pins.
Deterministic: no randomness, keys sorted.
"""
from __future__ import annotations

import copy
import importlib.util
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "appearance" / "vectors.json"
BACKEND_OUT = REPO / "backend" / "tests" / "data" / "appearance_vectors.json"
VERSION = 1

_spec = importlib.util.spec_from_file_location("appearance_reference", REPO / "backend" / "app" / "document" / "appearance.py")
ref = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = ref  # dataclasses look their module up while the file runs
_spec.loader.exec_module(ref)

BLUE, RED, GREEN, GREY, WHITE, BLACK = "#2F6FD6", "#D63A2F", "#2FD65A", "#D0D0D0", "#FFFFFF", "#202020"
WOOD, ORANGE = "#8B5A2B", "#E8834A"

# ---- the base assembly ------------------------------------------------------------------------------------------
# root R (own body "rb") places: frame -> F (sub-assembly), leg1 / leg2 -> L (one Part twice), bolt -> B (a pattern's
# source, copies bolt#pattern:p1:1..3).
# F (own body "fb") places barA / barB -> A (one Part twice) and sub -> G (a sub-assembly), and G places pin -> P.
# A has two bodies a1 / a2 and its own look: roughness 0.6 for the part, a2 wood, face 4 of a1 black.
BASE = {
    "parts": {
        "R": {
            "occurrences": {
                "frame": {"part_id": "F"},
                "leg1": {"part_id": "L"},
                "leg2": {"part_id": "L"},
                "bolt": {"part_id": "B"},
            }
        },
        "F": {"occurrences": {"barA": {"part_id": "A"}, "barB": {"part_id": "A"}, "sub": {"part_id": "G"}}},
        "G": {"occurrences": {"pin": {"part_id": "P"}}},
        "A": {
            "appearance": {"roughness": 0.6},
            "body_appearances": {"a2": {"colour": WOOD}},
            "face_appearances": [{"face": {"body_id": "a1", "index": 4}, "appearance": {"colour": BLACK}}],
        },
        "L": {},
        "B": {},
        "P": {},
    }
}


def model_with(changes: dict[str, dict]) -> dict:
    """BASE with per-Part keys replaced (`{part_id: {key: value}}`)."""
    model = copy.deepcopy(BASE)
    for part_id, fields in changes.items():
        model["parts"].setdefault(part_id, {}).update(copy.deepcopy(fields))
    return model


def ov(path: str = "", appearance: dict | None = None, **extra) -> dict:
    return {"path": path, **extra, "appearance": appearance or {}}


MODELS = {
    "base": BASE,
    "whole": model_with({"R": {"appearance_overrides": [ov("", {"colour": GREY})]}}),
    "frame_blue": model_with({"R": {"appearance_overrides": [ov("frame", {"colour": BLUE})]}}),
    "frame_blue_barA_red": model_with(
        {"R": {"appearance_overrides": [ov("frame", {"colour": BLUE}), ov("frame/barA", {"colour": RED})]}}
    ),
    "every_A": model_with({"R": {"appearance_overrides": [ov(appearance={"metallic": 1.0, "roughness": 0.3}, scope="same_part", part_id="A")]}}),
    "every_A_blue_barA_red": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov("frame/barA", {"colour": RED}),
                    ov(appearance={"colour": BLUE}, scope="same_part", part_id="A"),
                ]
            }
        }
    ),
    "every_A_over_frame": model_with(
        {"R": {"appearance_overrides": [ov("frame", {"colour": BLUE}), ov(appearance={"colour": RED}, scope="same_part", part_id="A")]}}
    ),
    "bolt_pattern": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov("bolt", {"colour": BLACK}, scope="pattern", pattern_id="p1"),
                    ov("bolt#pattern:p1:2", {"opacity": 0.3}),
                ]
            }
        }
    ),
    "frame_pattern": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov("frame", {"colour": BLUE}, scope="pattern", pattern_id="p2"),
                    ov("frame#pattern:p2:1", {"colour": RED}),
                ]
            }
        }
    ),
    "two_patterns_one_source": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov("bolt", {"colour": BLUE}, scope="pattern", pattern_id="p1"),
                    ov("bolt", {"colour": RED}, scope="pattern", pattern_id="p3"),
                ]
            }
        }
    ),
    "body_and_face": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov("frame/barA", {"colour": BLUE}),
                    ov("frame/barA", {"metallic": 1.0, "roughness": 0.2}, body_id="a1"),
                    ov("frame/barA", {"colour": WHITE, "emission": WHITE, "emission_strength": 2.0}, body_id="a1", face={"body_id": "a1", "index": 7}),
                ]
            }
        }
    ),
    "own_body_of_root": model_with(
        {"R": {"appearance": {"colour": WOOD}, "appearance_overrides": [ov("", {"colour": ORANGE}, body_id="rb")]}}
    ),
    "levels": model_with(
        {
            "R": {"appearance_overrides": [ov("frame/sub/pin", {"opacity": 0.5})]},
            "F": {"appearance_overrides": [ov("barA", {"colour": GREEN}), ov("sub/pin", {"colour": GREEN, "opacity": 0.9})]},
            "G": {"appearance_overrides": [ov("pin", {"colour": RED, "metallic": 0.4})]},
        }
    ),
    "levels_whole": model_with(
        {
            "R": {"appearance_overrides": [ov("", {"colour": GREY})]},
            "F": {"appearance_overrides": [ov("barA", {"colour": GREEN, "metallic": 1.0})]},
        }
    ),
    "sub_file_whole": model_with({"F": {"appearance_overrides": [ov("", {"colour": GREEN}), ov("", {"colour": ORANGE}, body_id="fb")]}}),
    "nested_subassemblies": model_with(
        {"R": {"appearance_overrides": [ov("frame", {"colour": BLUE}), ov("frame/sub", {"colour": RED})]}}
    ),
    "every_G_vs_pin": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov(appearance={"colour": BLUE, "opacity": 0.8}, scope="same_part", part_id="G"),
                    ov("frame/sub/pin", {"colour": RED}),
                ]
            }
        }
    ),
    "legacy": model_with({"R": {"occurrences": {**BASE["parts"]["R"]["occurrences"], "leg1": {"part_id": "L", "color": RED}}}}),
    "legacy_and_override": model_with(
        {
            "R": {
                "occurrences": {**BASE["parts"]["R"]["occurrences"], "leg1": {"part_id": "L", "color": RED}, "leg2": {"part_id": "L", "color": RED}},
                "appearance_overrides": [ov("leg1", {"opacity": 0.5}), ov("leg2", {"colour": BLUE})],
            }
        }
    ),
    "legacy_subassembly": model_with({"R": {"occurrences": {**BASE["parts"]["R"]["occurrences"], "frame": {"part_id": "F", "color": BLUE}}}}),
    "fieldwise": model_with({"R": {"appearance_overrides": [ov("frame/barB", {"opacity": 0.4})]}}),
    "same_part_body": model_with(
        {"R": {"appearance_overrides": [ov(appearance={"colour": ORANGE}, scope="same_part", part_id="A", body_id="a1")]}}
    ),
    "pattern_body": model_with(
        {"R": {"appearance_overrides": [ov("bolt", {"colour": ORANGE}, scope="pattern", pattern_id="p1", body_id="b1")]}}
    ),
    "pattern_copy_face": model_with(
        {
            "R": {
                "appearance_overrides": [
                    ov("frame#pattern:p2:1/barA", {"colour": RED}, body_id="a1", face={"body_id": "a1", "index": 2}),
                    ov("frame", {"colour": BLUE}, scope="pattern", pattern_id="p2"),
                ]
            }
        }
    ),
    "glow": model_with(
        {"R": {"appearance_overrides": [ov("leg1", {"emission": ORANGE}), ov("", {"emission_strength": 3.0, "colour": GREY})]}}
    ),
}

SCENE_RED_FRAME = [ov("frame", {"colour": RED, "opacity": 0.3})]
SCENE_BODY = [ov("frame/barA", {"colour": GREEN}, body_id="a2")]


def case(name: str, why: str, model: str, path: list[str], body_id: str | None = None, face_index: int | None = None, scene=None) -> dict:
    return {"name": name, "why": why, "model": model, "root": "R", "path": path, "body_id": body_id, "face_index": face_index, "scene_overrides": scene}


CASES = [
    case("nothing_set", "No appearance anywhere: nothing resolved (the renderer's default look).", "base", ["leg1"], "l1", 0),
    case("part_own", "The leaf Part's own appearance.", "base", ["frame", "barA"], "a1", 0),
    case("part_own_body", "The Part's own body appearance on top of its part appearance (field by field).", "base", ["frame", "barB"], "a2", 1),
    case("part_own_face", "The Part's own face beats its body and part (within one level, most specific wins).", "base", ["frame", "barA"], "a1", 4),
    case("whole_assembly", "An empty path paints everything in the assembly.", "whole", ["leg2"], "l1", 0),
    case("whole_beats_part_files", "Higher levels beat lower: the root's Whole assembly beats a Part's own face colour.", "whole", ["frame", "barA"], "a1", 4),
    case("whole_root_own_body", "Whole assembly covers the root's own bodies too.", "whole", [], "rb", 0),
    case("subassembly_inherits", "A sub-assembly override paints what is inside it.", "frame_blue", ["frame", "barB"], "a2", 0),
    case("subassembly_own_bodies", "A sub-assembly override paints the sub-assembly's own bodies.", "frame_blue", ["frame"], "fb", 0),
    case("subassembly_deep", "A sub-assembly override reaches every depth below it.", "frame_blue", ["frame", "sub", "pin"], "p1", 0),
    case("part_in_painted_subassembly", "A part painted inside a painted sub-assembly keeps its own colour.", "frame_blue_barA_red", ["frame", "barA"], "a1", 0),
    case("sibling_keeps_subassembly", "Its sibling keeps the sub-assembly colour.", "frame_blue_barA_red", ["frame", "barB"], "a1", 0),
    case("every_placement", "same_part paints every placement of the Part.", "every_A", ["frame", "barB"], "a1", 0),
    case("every_placement_this_one", "Every Frame A blue, then this Frame A red: this one is red.", "every_A_blue_barA_red", ["frame", "barA"], "a1", 0),
    case("every_placement_the_rest", "... and the rest stay blue.", "every_A_blue_barA_red", ["frame", "barB"], "a1", 0),
    case("every_placement_over_subassembly", "Every placement of a part beats the sub-assembly it sits in.", "every_A_over_frame", ["frame", "barA"], "a2", 0),
    case("subassembly_own_body_not_every_A", "... the sub-assembly's own bodies keep the sub-assembly colour.", "every_A_over_frame", ["frame"], "fb", 0),
    case("pattern_source", "Pattern (all N) paints the source.", "bolt_pattern", ["bolt"], "b1", 0),
    case("pattern_copy", "Pattern (all N) paints every copy.", "bolt_pattern", ["bolt#pattern:p1:3"], "b1", 0),
    case("pattern_copy_named", "One copy painted on its own beats the pattern; other fields come from the pattern.", "bolt_pattern", ["bolt#pattern:p1:2"], "b1", 0),
    case("pattern_other_pattern_copy", "A pattern override covers its own pattern only.", "bolt_pattern", ["bolt#pattern:p9:1"], "b1", 0),
    case("pattern_of_subassemblies", "Every copy of a patterned sub-assembly, inside it.", "frame_pattern", ["frame#pattern:p2:2", "barA"], "a1", 0),
    case("pattern_copy_subassembly_row", "That copy's own sub-assembly row beats the pattern.", "frame_pattern", ["frame#pattern:p2:1", "barA"], "a1", 0),
    case("pattern_tie_source", "A source in two painted patterns: the later override wins (a tie).", "two_patterns_one_source", ["bolt"], "b1", 0),
    case("pattern_tie_copy", "A copy belongs to one pattern only.", "two_patterns_one_source", ["bolt#pattern:p1:1"], "b1", 0),
    case("body_override", "A body override beats the part override, field by field.", "body_and_face", ["frame", "barA"], "a1", 0),
    case("body_override_other_body", "... and leaves the other body alone.", "body_and_face", ["frame", "barA"], "a2", 0),
    case("face_override", "A face override beats the body and part overrides.", "body_and_face", ["frame", "barA"], "a1", 7),
    case("face_override_other_part", "A face override names one placement only.", "body_and_face", ["frame", "barB"], "a1", 7),
    case("node_level_ignores_bodies", "With no body (the instance as a whole) only whole-node targets apply.", "body_and_face", ["frame", "barA"]),
    case("assembly_own_body", "An empty path with a body_id paints one of the assembly's own bodies.", "own_body_of_root", [], "rb", 0),
    case("assembly_own_other_body", "... not its other bodies (they keep the root Part's own look).", "own_body_of_root", [], "rb2", 0),
    case("root_part_appearance_stays_home", "A Part's own appearance never paints what it places.", "own_body_of_root", ["leg1"], "l1", 0),
    case("levels_top_wins", "The top assembly beats the sub-assembly files, field by field: opacity from R, colour from F.", "levels", ["frame", "sub", "pin"], "p1", 0),
    case("levels_sub_file_beats_part", "A sub-assembly file's override beats the Part's own look.", "levels", ["frame", "barA"], "a2", 0),
    case("levels_whole_beats_sub_file", "The root's Whole assembly beats a sub-assembly file's colour; the file's other fields stay.", "levels_whole", ["frame", "barA"], "a1", 0),
    case("sub_file_whole", "A sub-assembly file's own Whole assembly paints what it places.", "sub_file_whole", ["frame", "barB"], "a1", 0),
    case("sub_file_own_body", "... and its own body override beats its Whole assembly.", "sub_file_whole", ["frame"], "fb", 0),
    case("nested_subassembly_deeper_wins", "The nearer sub-assembly wins.", "nested_subassemblies", ["frame", "sub", "pin"], "p1", 0),
    case("every_G_paints_inside", "Every placement of a sub-assembly paints what is inside it.", "every_G_vs_pin", ["frame", "sub"], "g1", 0),
    case("pin_beats_every_G", "A part named inside it beats it; the opacity still comes from it.", "every_G_vs_pin", ["frame", "sub", "pin"], "p1", 0),
    case("legacy_colour", "Occurrence.color reads as an override.", "legacy", ["leg1"], "l1", 0),
    case("legacy_colour_not_sibling", "... for that occurrence only.", "legacy", ["leg2"], "l1", 0),
    case("legacy_plus_override", "An override that sets no colour keeps the legacy colour.", "legacy_and_override", ["leg1"], "l1", 0),
    case("override_colour_beats_legacy", "An override's own colour beats the legacy one.", "legacy_and_override", ["leg2"], "l1", 0),
    case("legacy_subassembly", "A legacy colour on a sub-assembly now paints what is inside it.", "legacy_subassembly", ["frame", "barB"], "a1", 0),
    case("fieldwise", "An override that sets only opacity keeps the colour from below.", "fieldwise", ["frame", "barB"], "a2", 0),
    case("same_part_body", "Every placement of a part, one body.", "same_part_body", ["frame", "barB"], "a1", 0),
    case("same_part_body_other_body", "... the other body keeps its own look.", "same_part_body", ["frame", "barB"], "a2", 0),
    case("pattern_body", "Every copy of a pattern, one body.", "pattern_body", ["bolt#pattern:p1:2"], "b1", 0),
    case("pattern_copy_face", "One face of a part inside one copy of a patterned sub-assembly.", "pattern_copy_face", ["frame#pattern:p2:1", "barA"], "a1", 2),
    case("pattern_copy_face_neighbour", "Its neighbour face takes the pattern.", "pattern_copy_face", ["frame#pattern:p2:1", "barA"], "a1", 3),
    case("glow_fields", "Emission and its strength resolve as separate fields.", "glow", ["leg1"], "l1", 0),
    case("scene_beats_all", "A shown scene beats every override.", "frame_blue_barA_red", ["frame", "barA"], "a1", 0, SCENE_RED_FRAME),
    case("scene_body", "A scene's body override applies to that body only.", "base", ["frame", "barA"], "a2", 0, SCENE_BODY),
    case("scene_body_other_body", "... the other body keeps the Part's own look.", "base", ["frame", "barA"], "a1", 4, SCENE_BODY),
    case("unresolved_path", "A path that does not resolve paints nothing.", "frame_blue", ["frame", "gone"], "x", 0),
]


def build() -> dict:
    cases = []
    for c in CASES:
        model = MODELS[c["model"]]
        expected = ref.resolve_appearance(model, c["root"], c["path"], c["body_id"], c["face_index"], c["scene_overrides"])
        cases.append({**c, "expected": expected})
    return {
        "version": VERSION,
        "source": "tools/appearance_vectors/generate.py (reference: backend/app/document/appearance.py)",
        "fields": list(ref.FIELDS),
        "models": MODELS,
        "cases": cases,
    }


def dumps(doc: dict) -> str:
    return json.dumps(doc, indent=1, sort_keys=True) + "\n"


def main() -> int:
    text = dumps(build())
    if "--check" in sys.argv:
        stale = [str(p.relative_to(REPO)) for p in (OUT, BACKEND_OUT) if not p.exists() or p.read_text() != text]
        if stale:
            print("stale: " + ", ".join(stale) + " (run tools/appearance_vectors/generate.py)")
            return 1
        print(f"ok: {len(CASES)} cases")
        return 0
    for path in (OUT, BACKEND_OUT):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    print(f"wrote {len(CASES)} cases to {OUT.relative_to(REPO)} and {BACKEND_OUT.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
