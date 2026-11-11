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

    {"result": "found" | "likely" | "ask" | "suggest" | "missing",
     "path": the file to use ("found" and "likely" only, else None),
     "via": "path" | "id" ("found") or "suffix" ("likely"), else None,
     "candidates": sorted paths for "ask" / "suggest", else [],
     "path_mismatch": True when a file is at the path but carries another id (report it, whatever else happens)}

1. The path: a file there with the stored id, or any file there when the reference has no stored id (an older file),
   is found `via: "path"`. A file there with a *different* id is not used: `path_mismatch`, and the search goes on.
2. The id: exactly one file in the index with the stored id is found `via: "id"` (the client uses it, says so, and
   writes the corrected path on the next save); several are `ask` (nothing is loaded until the user picks one).
2b. The folder shift (Flutter-testing feedback 2026-11-11, item 1b): changing the project folder adds or removes the same
   leading folders on every stored path. For a reference with **no stored id**, a file whose path equals the stored path
   after dropping leading segments from one of the two (`proj/parts/x.didsa` <-> `parts/x.didsa`; whole segments, native
   extension and letter case set aside as in step 3) is a path-suffix match. `k` is how many trailing segments agree. When
   exactly one file has the largest `k` of all name matches, that `k` is at least 2 (its own folder agrees as well as its
   name) and the match is a whole suffix (one path is the other with leading folders dropped), the answer is `likely`:
   `via: "suffix"`, `path` = that file. The rule never uses it by itself: the client asks the user first (or applies the
   session's stored answer). A reference with a stored id never gets `likely`: a suffix file that does not carry the id
   is only a suggestion (never a wrong file).
3. The name: files anywhere in the index with the reference's file name (native extension and letter case set aside),
   plus a mismatched file at the path, are only ever a `suggest`ion; never used without the user saying so. The candidates
   are ordered by `k` (most trailing segments in common first), then by path.
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


def _segments(path: str) -> list[str]:
    """A path's segments for the folder-shift step: separators unified, empty and `.` segments dropped, lower-cased, and the
    file name without its native extension (so `Proj/Parts/Bracket.didsa` -> `["proj", "parts", "bracket"]`)."""
    parts = [segment for segment in path.strip().replace("\\", "/").split("/") if segment and segment != "."]
    if not parts:
        return []
    return [segment.lower() for segment in parts[:-1]] + [name_key(parts[-1])]


def _shared_tail(a: list[str], b: list[str]) -> int:
    """How many trailing segments `a` and `b` have in common."""
    count = 0
    while count < min(len(a), len(b)) and a[-1 - count] == b[-1 - count]:
        count += 1
    return count


def _answer(
    result: str, path: str | None = None, via: str | None = None, candidates=(), mismatch: bool = False
) -> dict:
    return {"result": result, "path": path, "via": via, "candidates": list(candidates), "path_mismatch": mismatch}


def find_file(reference: dict, at_path: dict | None, index: list[dict]) -> dict:
    """Where the file `reference` places is now: see this module's docstring for the inputs, the answer and the steps."""
    ref_id = reference.get("ref_part_id") or None
    mismatch = False
    if at_path is not None:
        if ref_id is None or at_path.get("part_id") == ref_id:
            return _answer("found", at_path["path"], "path")
        mismatch = True
    if ref_id is not None:
        by_id = sorted({entry["path"] for entry in index if entry.get("part_id") == ref_id})
        if len(by_id) == 1:
            return _answer("found", by_id[0], "id", mismatch=mismatch)
        if by_id:
            return _answer("ask", candidates=by_id, mismatch=mismatch)
    external_ref = (reference.get("external_ref") or "").strip()
    if external_ref:
        wanted = _segments(external_ref)
        key = name_key(external_ref)
        by_name = {entry["path"] for entry in index if name_key(entry["path"]) == key}
        if mismatch:
            by_name.add(at_path["path"])
        if by_name:
            scored = sorted(
                ((_shared_tail(wanted, _segments(path)), path) for path in by_name), key=lambda item: (-item[0], item[1])
            )
            best_k, best_path = scored[0]
            unique_best = len(scored) == 1 or scored[1][0] < best_k
            whole_suffix = best_k == min(len(wanted), len(_segments(best_path)))
            if ref_id is None and unique_best and best_k >= 2 and whole_suffix:
                return _answer("likely", best_path, "suffix")
            return _answer("suggest", candidates=[path for _, path in scored], mismatch=mismatch)
    return _answer("missing", mismatch=mismatch)
