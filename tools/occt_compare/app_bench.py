"""App-level benchmark: build representative features through the real HTTP API, then mesh and STEP-export them.

Run from backend/: CAD_API_KEY=test-api-key python -I ../tools/occt_compare/app_bench.py OUT.json [reps]
"""
import json, os, statistics, sys, time
sys.path.insert(0, os.getcwd())

CASES = {
    "spur 20T m2": ("gear-features", {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 20, "face_width": 5.0}),
    "helical 30deg 20T": ("gear-features", {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 20, "face_width": 20.0, "helix_angle_degrees": 30.0}),
    "herringbone 25deg 24T": ("gear-features", {"gear_type": "boss", "is_internal": False, "module": 2.0, "tooth_count": 24, "face_width": 20.0, "helix_angle_degrees": 25.0, "herringbone": True}),
    "internal ring 60T": ("gear-features", {"gear_type": "boss", "is_internal": True, "module": 1.0, "tooth_count": 60, "face_width": 5.0, "outer_diameter": 70.0}),
    "planetary 20/60 x5": ("planetary-gear-features", {"module": 1.0, "sun_tooth_count": 20, "ring_tooth_count": 60, "planet_count": 5, "face_width": 5.0, "ring_outer_diameter": 70.0}),
    "bevel pair 20/40 straight": ("bevel-pair-features", {"module": 4.0, "member_1": {"tooth_count": 20}, "member_2": {"tooth_count": 40}, "face_width": 15.0}),
    "spiral bevel pair 10/20 20deg": ("bevel-pair-features", {"module": 4.0, "member_1": {"tooth_count": 10, "spiral_hand": "right"}, "member_2": {"tooth_count": 20, "spiral_hand": "left"}, "face_width": 8.0, "spiral_angle_degrees": 20.0}),
}


def main():
    t0 = time.perf_counter()
    from fastapi.testclient import TestClient
    from app.main import app
    import_s = time.perf_counter() - t0
    import OCC
    from tests.conftest import TEST_API_KEY

    client = TestClient(app)
    client.headers.update({"X-API-Key": TEST_API_KEY})
    reps = int(sys.argv[2]) if len(sys.argv) > 2 else 3
    results = {"pythonocc": OCC.VERSION, "import_app_s": import_s, "cases": {}}
    for name, (route, payload) in CASES.items():
        runs = []
        for _ in range(reps):
            part = client.post("/document/parts", json={"name": name}).json()
            s = time.perf_counter(); r = client.post(f"/document/parts/{part['id']}/{route}", json=payload); create = time.perf_counter() - s
            assert r.status_code == 201, (name, r.status_code, r.text[:300])
            warnings = r.json().get("warnings", [])
            s = time.perf_counter(); m = client.get(f"/document/parts/{part['id']}/mesh"); mesh = time.perf_counter() - s
            tris = sum(len(e["mesh"]["vertices"]) for e in m.json())
            s = time.perf_counter(); st = client.get(f"/document/parts/{part['id']}/export/step"); step = time.perf_counter() - s
            assert st.status_code == 200
            runs.append({"create_s": create, "mesh_s": mesh, "step_s": step, "step_bytes": len(st.content), "mesh_items": tris, "warnings": warnings})
        results["cases"][name] = {
            "create_s": statistics.median(r["create_s"] for r in runs),
            "mesh_s": statistics.median(r["mesh_s"] for r in runs),
            "step_s": statistics.median(r["step_s"] for r in runs),
            "step_bytes": runs[0]["step_bytes"],
            "mesh_items": runs[0]["mesh_items"],
            "warnings": runs[0]["warnings"],
        }
        print(name, {k: (round(v, 3) if isinstance(v, float) else v) for k, v in results["cases"][name].items() if k != "warnings"}, len(runs[0]["warnings"]), "warnings", flush=True)
    import resource
    results["max_rss_mb"] = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    json.dump(results, open(sys.argv[1], "w"), indent=1)


if __name__ == "__main__":
    main()
