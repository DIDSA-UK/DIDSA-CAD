"""`app.document.remint_identity.remint_native_identity` against the tester's
two real files (bug report 2026-10-14, item 3): `frame_a_save_as_source` (800
mm) and `frame_b_save_as_copy` (1600 mm), which share a `document.id`, a Part
id and three sketch ids because B is a Save-As copy of A that was then
edited."""

import json
from pathlib import Path

from app.document.native_format import import_native
from app.document.remint_identity import collect_native_identity_ids, remint_native_identity

DATA = Path(__file__).parent / "data"


def _load(name: str) -> dict:
    return json.loads((DATA / name).read_text())


def test_fixtures_really_share_identity():
    a = _load("frame_a_save_as_source.DIDSAprt")
    b = _load("frame_b_save_as_copy.DIDSAprt")
    assert collect_native_identity_ids(a) == collect_native_identity_ids(b)
    assert len(collect_native_identity_ids(a)) == 5  # document + 1 Part + 3 sketches


def test_remint_replaces_every_session_global_id_and_reference():
    a = _load("frame_a_save_as_source.DIDSAprt")
    old_ids = collect_native_identity_ids(a)
    original = json.dumps(a, sort_keys=True)

    minted = remint_native_identity(a)

    assert json.dumps(a, sort_keys=True) == original  # input untouched
    new_ids = collect_native_identity_ids(minted)
    assert len(new_ids) == len(old_ids)
    assert new_ids.isdisjoint(old_ids)
    # Not one stray reference to an old id anywhere in the tree.
    serialised = json.dumps(minted)
    assert not any(old in serialised for old in old_ids)
    # References follow: root_part_id, every sketch feature's sketch_id.
    document = minted["document"]
    part = document["parts"][0]
    assert document["root_part_id"] == part["id"]
    sketch_ids = {sketch["id"] for sketch in minted["sketches"]}
    referenced = {f["sketch_id"] for f in part["features"] if f.get("type") == "sketch"}
    assert referenced == sketch_ids


def test_remint_keeps_feature_ids_and_content():
    a = _load("frame_a_save_as_source.DIDSAprt")
    minted = remint_native_identity(a)
    old_features = a["document"]["parts"][0]["features"]
    new_features = minted["document"]["parts"][0]["features"]
    assert [f["id"] for f in new_features] == [f["id"] for f in old_features]
    assert [f.get("end_distance") for f in new_features] == [f.get("end_distance") for f in old_features]


def test_remint_only_ids_restricts_the_replacement():
    a = _load("frame_a_save_as_source.DIDSAprt")
    part_id = a["document"]["parts"][0]["id"]
    minted = remint_native_identity(a, only_ids={part_id})
    assert minted["document"]["parts"][0]["id"] != part_id
    assert minted["document"]["id"] == a["document"]["id"]
    assert [s["id"] for s in minted["sketches"]] == [s["id"] for s in a["sketches"]]


def test_reminted_payload_still_imports():
    a = _load("frame_a_save_as_source.DIDSAprt")
    minted = remint_native_identity(a)
    document, sketches = import_native(minted)
    assert list(document.parts) == [minted["document"]["parts"][0]["id"]]
    assert set(sketches) == {s["id"] for s in minted["sketches"]}


def test_each_remint_yields_distinct_ids():
    a = _load("frame_a_save_as_source.DIDSAprt")
    first = collect_native_identity_ids(remint_native_identity(a))
    second = collect_native_identity_ids(remint_native_identity(a))
    assert first.isdisjoint(second)
