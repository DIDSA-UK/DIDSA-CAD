"""A scripted live session against a REAL backend and a REAL hub (docs/live-sessions-scope.md; the plan's P1 test, end to end):
a presenter builds a small assembly over REST, mints a view token, hosts; two observers join with the code alone, fetch the glb
from the backend with only the token (200, then 304), are refused anything else, follow a pose stream and a document change,
and a late joiner gets the snapshot. Also usable by P2 as a stand-in presenter or observer for the headset.

Not collected by pytest (it needs both services running). Usage:
    CAD_URL=http://127.0.0.1:8000 CAD_KEY=... HUB_URL=ws://127.0.0.1:8300 HUB_KEY=... python tools/scripted_session.py
Exits 0 when every check passed; prints one line per check.
"""

import asyncio
import json
import os
import sys
import uuid

import httpx
from websockets.asyncio.client import connect

CAD_URL = os.environ.get("CAD_URL", "http://127.0.0.1:8000")
CAD_KEY = os.environ["CAD_KEY"]
HUB_URL = os.environ.get("HUB_URL", "ws://127.0.0.1:8300")
HUB_KEY = os.environ["HUB_KEY"]
XF = [1, 0, 0, 0, 1, 0, 0, 0, 1, 15.0, 0.0, 10.0]

failures = 0


def check(ok: bool, what: str) -> None:
    global failures
    print(("ok   " if ok else "FAIL ") + what)
    failures += 0 if ok else 1


async def until(ws, kind: str) -> dict:
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=10)
        if isinstance(raw, bytes):
            continue
        message = json.loads(raw)
        if message["t"] == kind:
            return message


def box(cad: httpx.Client, name: str, size: float) -> dict:
    part = cad.post("/document/parts", json={"name": name}).json()
    sketch = cad.post(f"/document/parts/{part['id']}/features/sketch", json={"plane": "XY"}).json()
    pts = [cad.post(f"/sketch/sketches/{sketch['sketch_id']}/points", json={"x": x, "y": y}).json() for x, y in [(0, 0), (size, 0), (size, size), (0, size)]]
    for a, b in zip(pts, pts[1:] + pts[:1]):
        cad.post(f"/sketch/sketches/{sketch['sketch_id']}/lines", json={"start_point_id": a["id"], "end_point_id": b["id"]})
    cad.post(f"/document/parts/{part['id']}/extrude-features", json={"sketch_feature_id": sketch["id"], "extrude_type": "boss", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": []})
    return part


def build_assembly(cad: httpx.Client) -> str:
    root, child = box(cad, "Mount", 20.0), box(cad, "Bolt", 2.0)
    root_export = cad.get("/document/export/native", params={"part_id": root["id"]}).json()
    child_export = cad.get("/document/export/native", params={"part_id": child["id"]}).json()
    root_dict = root_export["document"]["parts"][0]
    root_dict["occurrences"] = [{"id": "occ-bolt", "external_ref": "parts/bolt.didsa", "resolved_part_id": child["id"], "name_override": None,
                                 "transform": {"translation": [15.0, 0.0, 10.0], "rotation_axis": [0, 0, 1], "rotation_angle_degrees": 0.0},
                                 "suppressed": False, "hidden": False, "color": None}]
    root_dict["mates"] = []
    payload = {"schema_version": root_export["schema_version"],
               "document": {"id": "scripted", "root_part_id": root["id"], "parts": [root_dict, child_export["document"]["parts"][0]]},
               "sketches": [*root_export["sketches"], *child_export["sketches"]]}
    assert cad.post("/document/import/native", json=payload).status_code == 200
    return root["id"]


async def main() -> int:
    cad = httpx.Client(base_url=CAD_URL, headers={"X-API-Key": CAD_KEY, "X-Document-Session": f"scripted-{uuid.uuid4()}"}, timeout=60)
    root = build_assembly(cad)
    minted = cad.post("/document/view-tokens", json={"root_part_id": root})
    check(minted.status_code == 201, "presenter mints a view token")
    token, rev = minted.json()["token"], minted.json()["rev"]

    async with connect(f"{HUB_URL}/ws", additional_headers={"X-API-Key": HUB_KEY}) as presenter:
        await presenter.send(json.dumps({"t": "host", "proto": 1, "name": "Scripted presenter", "device": "desktop", "client": "scripted_session.py",
                                         "model": {"kind": "backend", "root_part_id": root, "rev": rev, "quality": 0.5, "tier": "full"},
                                         "backend_url": CAD_URL, "view_token": token}))
        code = (await until(presenter, "welcome"))["room"]["code"]
        check(len(code) == 6, f"room hosted, code {code}")

        observers = []
        for name in ("Observer A", "Observer B"):
            ws = await connect(f"{HUB_URL}/ws")
            await ws.send(json.dumps({"t": "join", "proto": 1, "code": code, "name": name, "device": "phone"}))
            welcome = await until(ws, "welcome")
            observers.append((ws, welcome))
        check(all(w["view_token"] == token and w["backend_url"] == CAD_URL for _, w in observers), "both observers got the token and the backend address from the hub")

        viewer = httpx.Client(base_url=observers[0][1]["backend_url"], headers={"X-View-Token": observers[0][1]["view_token"]}, timeout=60)
        glb_path = f"/document/parts/{root}/assembly-mesh.glb"
        first = viewer.get(glb_path)
        check(first.status_code == 200 and first.content[:4] == b"glTF", f"observer fetched the glb with only the token ({len(first.content)} bytes)")
        again = viewer.get(glb_path, headers={"If-None-Match": first.headers.get("etag", "")})
        check(again.status_code == 304, "a refetch at the same revision is 304")
        for method, path in [("GET", f"/document/parts/{root}"), ("GET", "/document/export/native"), ("PATCH", f"/document/parts/{root}/occurrences/occ-bolt")]:
            refused = viewer.request(method, path, json={} if method != "GET" else None)
            check(refused.status_code == 401, f"observer refused {method} {path.replace(root, '<root>')}")

        await presenter.send(json.dumps({"t": "poses", "seq": 1, "full": True, "items": [{"path": "occ-bolt", "xf": XF}]}))
        got = [await until(ws, "poses") for ws, _ in observers]
        check(all(g["items"][0]["xf"] == XF for g in got), "both observers got the pose stream")

        moved = cad.patch(f"/document/parts/{root}/occurrences/occ-bolt", json={"hidden": True})
        new_rev = int(moved.headers["x-document-revision"])
        check(new_rev > rev, f"an edit bumped the revision ({rev} -> {new_rev})")
        await presenter.send(json.dumps({"t": "doc_changed", "seq": 2, "rev": new_rev, "all": True}))
        changed = await until(observers[1][0], "doc_changed")
        refetch = httpx.get(CAD_URL + glb_path, headers={"X-View-Token": token, "If-None-Match": first.headers.get("etag", "")}, timeout=60)
        check(changed["rev"] == new_rev and refetch.status_code == 200 and refetch.content != first.content, "doc_changed reached the observer and its refetch got the new glb")

        late = await connect(f"{HUB_URL}/ws")
        await late.send(json.dumps({"t": "join", "proto": 1, "code": code, "name": "Late", "device": "quest"}))
        snap = (await until(late, "welcome"))["snapshot"]
        check(snap["rev"] == new_rev and snap["poses"][0]["path"] == "occ-bolt", "a late joiner got the latest revision and poses")

        await presenter.send(json.dumps({"t": "end"}))
        check((await until(late, "end"))["reason"] == "ended", "end reached everyone")
        revoked = cad.delete(f"/document/view-tokens/{token}")
        check(revoked.status_code == 204 and viewer.get(glb_path).status_code == 401, "the token is revoked at the end")
        for ws, _ in observers:
            await ws.close()
        await late.close()
    print(f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
