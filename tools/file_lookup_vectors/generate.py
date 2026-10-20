#!/usr/bin/env python3
"""Golden vectors for finding moved files (docs/moved-files-scope.md section 2: "reference, stored id, the file found at
the path or none, index -> found | ask | suggest | missing").

    python tools/file_lookup_vectors/generate.py            # (re)writes docs/file-lookup/vectors.json
    python tools/file_lookup_vectors/generate.py --check    # exits 1 if a committed copy differs

The reference is `backend/app/document/file_lookup.py` (pure Python, so this runs on a plain python3). DIDSA-VR (GDScript)
and the flat app (Dart) copy the rule and are tested against `docs/file-lookup/vectors.json`; the backend's own copy
(`backend/tests/data/file_lookup_vectors.json`, the CI image holds backend/ only) pins the reference.

Each case: `reference` {external_ref, ref_part_id}, `at_path` (null or {path, part_id}), `index` ([{path, part_id}]) and
`expected` (the rule's answer: result, path, via, candidates, path_mismatch).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "docs" / "file-lookup" / "vectors.json"
BACKEND_OUT = REPO / "backend" / "tests" / "data" / "file_lookup_vectors.json"
sys.path.insert(0, str(REPO / "backend"))

from app.document.file_lookup import find_file  # noqa: E402

VERSION = 1

FRAME = "f676588a-frame"
OTHER = "0b1d2e3f-other"
REF = "parts/Frame A.didsa"


def ref(external_ref: str | None = REF, ref_part_id: str | None = FRAME) -> dict:
    return {"external_ref": external_ref, "ref_part_id": ref_part_id}


def entry(path: str, part_id: str | None) -> dict:
    return {"path": path, "part_id": part_id}


# (name, why, reference, at_path, index)
CASES = [
    ("path_with_its_id", "Step 1: the file at the path carries the stored id.",
     ref(), entry(REF, FRAME), [entry(REF, FRAME), entry("parts/frames/Frame A.didsa", FRAME)]),
    ("path_older_reference", "Step 1: an older reference (no stored id) takes whatever file is at the path, as before.",
     ref(ref_part_id=None), entry(REF, OTHER), [entry(REF, OTHER)]),
    ("path_other_extension", "Step 1: the client's path lookup found it under another native extension; that path is used.",
     ref(), entry("parts/frame a.DIDSAprt", FRAME), [entry("parts/frame a.DIDSAprt", FRAME)]),
    ("moved_found_by_id", "Step 2: the path misses; exactly one file in the project folder has the id: use it.",
     ref(), None, [entry("parts/frames/Frame A.didsa", FRAME), entry("parts/Bolt.didsa", OTHER)]),
    ("renamed_found_by_id", "Step 2: renamed outside the app: a different name, the same id.",
     ref(), None, [entry("parts/Frame A (left).didsa", FRAME), entry("parts/Frame B.didsa", OTHER)]),
    ("id_beats_name", "Step 2 before step 3: a same-name file with another id is not offered when the id is found.",
     ref(), None, [entry("old/Frame A.didsa", OTHER), entry("parts/frames/Frame A.didsa", FRAME)]),
    ("two_copies_ask", "Step 2: two files carry the id (a copy made outside the app): ask, nothing loaded.",
     ref(), None, [entry("parts/b/Frame A.didsa", FRAME), entry("parts/a/Frame A.didsa", FRAME)]),
    ("path_mismatch_found_by_id", "Steps 1 and 2: the path now holds another file, the real one moved: use the id match, report the mismatch.",
     ref(), entry(REF, OTHER), [entry(REF, OTHER), entry("archive/Frame A.didsa", FRAME)]),
    ("path_mismatch_suggest", "Step 3: the path holds another file and the id is nowhere: that file is only a suggestion.",
     ref(), entry(REF, OTHER), [entry(REF, OTHER)]),
    ("path_mismatch_unread_file", "Step 1: a file at the path whose id could not be read is not taken as a match.",
     ref(), entry(REF, None), [entry(REF, None)]),
    ("older_reference_name_suggest", "Step 3: an older reference, the path misses: same-name files are suggestions, never used.",
     ref(ref_part_id=None), None, [entry("parts/frames/frame a.didsa", OTHER), entry("old/Frame A.DIDSAprt", None), entry("parts/Bolt.didsa", FRAME)]),
    ("id_missing_name_suggest", "Step 3: the id is not in the index; a same-name file with another id is a suggestion.",
     ref(), None, [entry("parts/frames/Frame A.didsa", OTHER)]),
    ("missing", "Step 4: nothing with the id or the name: missing (Locate...).",
     ref(), None, [entry("parts/Bolt.didsa", OTHER)]),
    ("missing_empty_index", "Step 4: an empty project folder.",
     ref(ref_part_id=None), None, []),
    ("no_external_ref", "Step 4: an occurrence with no path and an id nowhere to be found.",
     ref(external_ref=None), None, [entry("parts/Frame A.didsa", OTHER)]),
    ("no_external_ref_found_by_id", "Step 2 needs no path: the id alone finds the file.",
     ref(external_ref=None), None, [entry("parts/Frame A.didsa", FRAME)]),
]


def build() -> dict:
    cases = []
    for name, why, reference, at_path, index in CASES:
        cases.append({"name": name, "why": why, "reference": reference, "at_path": at_path, "index": index,
                      "expected": find_file(reference, at_path, index)})
    return {"version": VERSION, "source": "tools/file_lookup_vectors/generate.py (reference: backend/app/document/file_lookup.py)",
            "cases": cases}


def dumps(doc: dict) -> str:
    return json.dumps(doc, indent=1, sort_keys=True) + "\n"


def main() -> int:
    text = dumps(build())
    if "--check" in sys.argv:
        stale = [str(p.relative_to(REPO)) for p in (OUT, BACKEND_OUT) if not p.exists() or p.read_text() != text]
        if stale:
            print("stale: " + ", ".join(stale) + " (run tools/file_lookup_vectors/generate.py)")
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
