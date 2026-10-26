# Comparing two OCCT / pythonocc-core versions

Used for `docs/occt-8-upgrade-evaluation.md`; rerun them for the next kernel bump. Make two conda envs from
`backend/environment.yml` that differ only in the `pythonocc-core` pin (check with `micromamba list`), then, from
`backend/`, in each env:

```
# every body the suite builds, after every feature step: volume, area, centroid, topology counts, validity
GEOMDIFF_OUT=/tmp/gd_old PYTHONPATH=../tools/occt_compare python -m pytest tests/ -n 4 -p geomdiff
python -I ../tools/occt_compare/compare_geom.py /tmp/gd_old /tmp/gd_new

python -I ../tools/occt_compare/kernel_bench.py /tmp/kernel_old.json      # Booleans, many-hole check, fillet, mesh, STEP
CAD_API_KEY=test-api-key python -I ../tools/occt_compare/app_bench.py /tmp/app_old.json 3   # gears through the HTTP API
```

Run the benchmarks one at a time on an idle machine, and compare runs of the same code: a behaviour change can make a
build skip work (the 2026-10-26 evaluation saw spiral bevel pairs look 10x faster because a bug skipped their search).
