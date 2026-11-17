"""N1b, test plan items 3 and 5, on the gear-train demo (DIDSA-VR `demo/assemblies/gear_train/Gear_train.didsa`; both versions are copied into `tests/data` so this
repo's CI needs no VR checkout):

* the CURRENT demo (VR commit 5d8faaf: bevel faces 105 and 104) opens with no reference flags, adopts its (unsigned) references silently because the stored
  placement confirms them, and the group solve is exactly what it was before N1b (`gear_train_demo_motion.json` was recorded on `main` at ccc11be);
* the OLD demo (VR commit 0c5a08c: the bevel mates name faces 3 and 4, which the bevel body no longer has there: N0) is NOT adopted: the mates that name them
  are held as `unconfirmed` and read `broken`, and the group solve leaves them out and names them instead of failing with `unsupported_mate_geometry` (the 422 N0
  saw);
* a mate on the bevel's bore, its index renumbered onto the rim that shares its axis, is followed by radius (N1a's rule), end to end.

The file name says `gear`, so conftest marks it `gears`."""

import json

import pytest

from app.document.subshape_identity import iter_mate_subshape_refs
from tests.gear_train_demo_motion_source import DATA, import_demo, record
from tests.test_mate_reference_identity import _json, _mate, _stored_mate, _write_index, client

_OLD = DATA / "gear_train_demo_old_bevel_indices.didsa"
_FLAGS = ("lost_references", "moved_references", "followed_references")


def _listing(root):
    return _json(client.get(f"/document/parts/{root}/mates"))


def test_the_current_demo_opens_with_no_reference_flags_and_adopts_silently():
    root = import_demo(client)
    assert all(ref.signature is None for m in _stored_mates(root) for _p, ref in iter_mate_subshape_refs(m))  # the file has none
    mates = _listing(root)
    assert len(mates) == 18
    for m in mates:
        assert all(m[f] == [] for f in _FLAGS) and m["held"] is False and m["reference_reasons"] == {}, (m["type"], m["reference_reasons"])
        assert m["status"] == "ok", m["type"]
    # adopted and persisted: signed now, the next save carries them
    assert all(ref.signature is not None for m in _stored_mates(root) for _p, ref in iter_mate_subshape_refs(m))
    assert _json(client.get("/document/export/native"))  # the export refreshes again: nothing to say


def _stored_mates(root):
    from app.document.router import get_part_or_404

    return get_part_or_404(root).mates


def _differs(got, want, path="", flip=False):
    """None when `got` is `want` to 1e-6. The recording is one machine's (x86-64); on another CPU (CI's arm64 runner) the free-motion `basis` comes out with the
    opposite overall sign (a null-space vector has no sign), so each basis row may be negated as a whole."""
    if isinstance(want, dict):
        if not isinstance(got, dict) or set(got) != set(want):
            return f"{path}: keys differ"
        return next((d for k in want if (d := _differs(got[k], want[k], f"{path}.{k}")) is not None), None)
    if isinstance(want, list) and path.endswith("basis"):
        for g, w in zip(got, want):
            if _differs(g, w, path) is not None and _differs(g, [-x for x in w], path) is not None:
                return f"{path}: a basis row differs beyond its sign"
        return None if len(got) == len(want) else f"{path}: row count"
    if isinstance(want, list):
        if not isinstance(got, list) or len(got) != len(want):
            return f"{path}: length"
        return next((d for i, (g, w) in enumerate(zip(got, want)) if (d := _differs(g, w, f"{path}[{i}]")) is not None), None)
    if isinstance(want, float) and not isinstance(want, bool):
        return None if abs(got - want) <= 1e-6 else f"{path}: {got} != {want}"
    return None if got == want else f"{path}: {got!r} != {want!r}"


@pytest.mark.parametrize("list_first", [False, True], ids=["solve_before_any_listing", "listing_first"])
def test_mate_motion_on_the_current_demo_is_what_it_was_before_n1b(list_first):
    root = import_demo(client)
    if list_first:
        _listing(root)
    got = record(client, root)
    want = json.loads((DATA / "gear_train_demo_motion.json").read_text())
    assert set(got) == set(want)
    for key in want:
        problem = _differs(got[key], want[key])
        assert problem is None, f"{key}: {problem}"
    assert all(got[k]["converged"] for k in want if k != "constraint_status")


def test_the_old_demo_is_broken_with_a_reason_and_never_adopted():
    root = import_demo(client, _OLD)
    mates = _listing(root)
    held = [m for m in mates if m["held"]]
    clean = [m for m in mates if not m["held"]]
    # the six mates that name a bevel face by its old index (3 or 4): two Concentric / Coincident pairs and the two gear couplers on a bevel
    assert len(held) == 6 and len(clean) == 12, [(m["type"], m["held"]) for m in mates]
    for m in held:
        assert m["moved_references"] and set(m["reference_reasons"].values()) == {"unconfirmed"}, m["reference_reasons"]
        assert m["lost_references"] == [] and m["status"] == "broken"
    for m in clean:
        assert all(m[f] == [] for f in _FLAGS) and m["status"] == "ok", (m["type"], m["status"])
    bevel_refs = [
        ref
        for m in _stored_mates(root)
        if m.id in {h["id"] for h in held}
        for _p, ref in iter_mate_subshape_refs(m)
        if ref.index in (3, 4) and ref.body_id and ref.signature is None
    ]
    assert bevel_refs, "the old indices were adopted (signed)"


def test_the_group_solve_of_the_old_demo_leaves_the_held_mates_out_instead_of_failing():
    root = import_demo(client, _OLD)
    ids = {m["id"] for m in _listing(root) if m["held"]}
    stored = {o["id"]: o["transform"] for o in client.get(f"/document/parts/{root}/occurrences").json()}
    response = client.post(f"/document/parts/{root}/occurrences/crank/mate-motion", json={"transform": stored["crank"]})
    assert response.status_code == 200, response.text  # before N1b: 422 unsupported_mate_geometry (N0)
    body = response.json()
    assert body["converged"] and body["held_mate_ids"] and set(body["held_mate_ids"]) <= ids


def test_a_mate_on_the_bevel_bore_renumbered_onto_the_rim_is_followed_by_radius():
    root = import_demo(client)
    mates = _listing(root)  # signs everything
    bore = 105
    concentric = next(m for m in mates if m["type"] == "concentric" and m["references"][0]["occurrence_id"] == "bevel_a")
    path = "references[0].subshape_ref"
    assert concentric["references"][0]["subshape_ref"]["index"] == bore
    assert _stored_mate(root, concentric["id"]).references[0].subshape_ref.signature.radius == pytest.approx(4.0)
    _write_index(root, concentric["id"], path, 81)  # the rim (R 28.04), on the same axis: what a renumbering would hand the index
    listed = _mate(root, concentric["id"])
    assert path in listed["followed_references"] and listed["reference_reasons"][path] == "nearest_radius"
    assert listed["references"][0]["subshape_ref"]["index"] == bore and listed["held"] is False and listed["status"] == "ok"
    assert _stored_mate(root, concentric["id"]).references[0].subshape_ref.index == bore
