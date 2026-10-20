"""Finding moved files (`docs/moved-files-scope.md` section 2): the rule both clients use to find the file an
Occurrence places when its path misses. Pure Python (no OCCT, no pydantic), so it is the reference the clients copy:
DIDSA-VR (GDScript) and the flat app (Dart) are tested against the golden vectors
`tools/file_lookup_vectors/generate.py` writes to `docs/file-lookup/vectors.json`. The backend itself never runs it
(it has no file system); it stores `Occurrence.ref_part_id`, the id step 2 looks up.

Inputs, as plain values:

    reference = {"external_ref": "parts/Frame A.didsa", "ref_part_id": "f676..." or None}
    at_path   = {"path": "parts/Frame A.didsa", "part_id": "f676..." or None} or None
                # the file the client's existing path lookup found (exact name, then another native extension or
                # letter case in the same folder), with the root Part id read from it; None when it found nothing
    index     = [{"path": "parts/frames/Frame A.didsa", "part_id": "f676..." or None}, ...]
                # every native file in the project folder (DIDSA-VR: and the models folders), with its root Part id
                # (None when the file could not be read)

The answer, always with the same keys:

    {"result": "found" | "ask" | "suggest" | "missing",
     "path": the file to use ("found" only, else None),
     "via": "path" | "id" ("found" only, else None),
     "candidates": sorted paths for "ask" / "suggest", else [],
     "path_mismatch": True when a file is at the path but carries another id (report it, whatever else happens)}

1. The path: a file there with the stored id, or any file there when the reference has no stored id (an older file),
   is found `via: "path"`. A file there with a *different* id is not used: `path_mismatch`, and the search goes on.
2. The id: exactly one file in the index with the stored id is found `via: "id"` (the client uses it, says so, and
   writes the corrected path on the next save); several are `ask` (nothing is loaded until the user picks one).
3. The name: files anywhere in the index with the reference's file name (native extension and letter case set aside),
   plus a mismatched file at the path, are only ever a `suggest`ion; never used without the user saying so.
4. Otherwise `missing` (unresolved as before; the client offers Locate...).
"""

NATIVE_EXTENSIONS = ("didsa", "DIDSAprt", "didsacad")  # as DIDSA-VR native_compose.gd / the flat app's relative_path.dart


def name_key(path: str) -> str:
    """A file's name for step 3: the last path segment, lower-cased, with any native extension removed, so
    `parts/Bracket.didsa` and `old/bracket.DIDSAprt` compare equal."""
    name = path.strip().replace("\\", "/").rsplit("/", 1)[-1]
    lower = name.lower()
    for extension in NATIVE_EXTENSIONS:
        suffix = "." + extension.lower()
        if lower.endswith(suffix):
            return lower[: -len(suffix)]
    return lower


def _answer(result: str, path: str | None = None, via: str | None = None, candidates=(), mismatch: bool = False) -> dict:
    return {"result": result, "path": path, "via": via, "candidates": sorted(set(candidates)), "path_mismatch": mismatch}


def find_file(reference: dict, at_path: dict | None, index: list[dict]) -> dict:
    """Where the file `reference` places is now: see this module's docstring for the inputs, the answer and the steps."""
    ref_id = reference.get("ref_part_id") or None
    mismatch = False
    if at_path is not None:
        if ref_id is None or at_path.get("part_id") == ref_id:
            return _answer("found", at_path["path"], "path")
        mismatch = True
    if ref_id is not None:
        by_id = [entry["path"] for entry in index if entry.get("part_id") == ref_id]
        if len(by_id) == 1:
            return _answer("found", by_id[0], "id", mismatch=mismatch)
        if by_id:
            return _answer("ask", candidates=by_id, mismatch=mismatch)
    external_ref = (reference.get("external_ref") or "").strip()
    if external_ref:
        key = name_key(external_ref)
        by_name = [entry["path"] for entry in index if name_key(entry["path"]) == key]
        if mismatch:
            by_name.append(at_path["path"])
        if by_name:
            return _answer("suggest", candidates=by_name, mismatch=mismatch)
    return _answer("missing", mismatch=mismatch)
